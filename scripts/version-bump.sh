#!/usr/bin/env bash
# Auto-versioning for the super-status repo. Invoked from .git/hooks/post-commit
# after every commit: derives a semver bump from the commit type (Conventional
# Commits), prepends a plain-English row to the per-year ledger versions/<year>.md
# (creating that file with a header on the first commit of a new year) in a
# follow-up "chore(version)" ledger commit, tags it vX.Y.Z, then pushes the branch
# and the tag. The tagged ledger commit is the anchor a revert restores to.
#
# The plain-English "Change" cell is sourced from .git/version-note.md if one was
# written before committing (one bullet per line), else falls back to a de-jargoned
# commit subject — so a readable row always exists.
#
# Loop-safe: guarded by a lock file and by skipping its own ledger commits. A
# non-zero exit never fails the triggering commit (git ignores post-commit status).
set -uo pipefail

REPO="$HOME/Repos/super-status"
cd "$REPO" || exit 0

VERSIONS_DIR="versions"
NOTE_FILE=".git/version-note.md"
LOCK=".git/version-bump.lock"

# --- guards -------------------------------------------------------------------
[ -f "$LOCK" ] && exit 0
{ [ -d ".git/rebase-merge" ] || [ -d ".git/rebase-apply" ] || [ -f ".git/MERGE_HEAD" ]; } && exit 0

SUBJECT="$(git log -1 --format=%s)"
BODY="$(git log -1 --format=%b)"
case "$SUBJECT" in "chore(version):"*) exit 0 ;; esac  # never version our own ledger commits

# --- classify the bump from the commit type -----------------------------------
bump="patch"
if printf '%s\n%s\n' "$SUBJECT" "$BODY" | grep -q 'BREAKING CHANGE' \
   || printf '%s' "$SUBJECT" | grep -qE '^[a-z]+(\([^)]*\))?!:'; then
  bump="major"
elif printf '%s' "$SUBJECT" | grep -qE '^feat(\([^)]*\))?:'; then
  bump="minor"
fi

# --- compute the next version from the latest vX.Y.Z tag ----------------------
latest="$(git tag -l 'v[0-9]*.[0-9]*.[0-9]*' | sed 's/^v//' \
          | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
latest="${latest:-0.0.0}"
IFS=. read -r major minor patch <<< "$latest"
case "$bump" in
  major) major=$((major + 1)); minor=0; patch=0 ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  patch) patch=$((patch + 1)) ;;
esac
next="$major.$minor.$patch"

code_sha="$(git log -1 --format=%h)"
commit_time="$(git log -1 --format=%cd --date=format:'%d/%m/%Y %H:%M:%S')"
year="$(git log -1 --format=%cd --date=format:'%Y')"

# --- resolve the per-year ledger; create it with a header on first use --------
year_file="$VERSIONS_DIR/$year.md"
mkdir -p "$VERSIONS_DIR"
if [ ! -f "$year_file" ]; then
  cat > "$year_file" <<EOF
# $year

Version history for $year — newest first. Each row is an exact, revertable point
(a tagged commit). Recorded automatically on every commit; never edit by hand.

| Version | Time | Commit | Change |
|---|---|---|---|
EOF
fi

# --- build the plain-English Change cell (bullets joined with <br>) -----------
cell=""
if [ -s "$NOTE_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*[-*•][[:space:]]*//; s/[[:space:]]+$//')"
    [ -z "$line" ] && continue
    if [ -z "$cell" ]; then cell="• $line"; else cell="$cell<br>• $line"; fi
  done < "$NOTE_FILE"
fi
if [ -z "$cell" ]; then
  clean="$(printf '%s' "$SUBJECT" | sed -E 's/^[a-z]+(\([^)]*\))?!?:[[:space:]]*//')"
  clean="$(printf '%s' "${clean:0:1}" | tr '[:lower:]' '[:upper:]')${clean:1}"
  cell="• $clean"
fi

row="| $next | $commit_time | \`$code_sha\` | $cell |"

# --- prepend the row after the year ledger's table separator, then commit + tag
tmp="$(mktemp)"
awk -v row="$row" '
  { print }
  !done && /^[[:space:]]*\|[-: |]+\|[[:space:]]*$/ { print row; done = 1 }
' "$year_file" > "$tmp" && mv "$tmp" "$year_file"

# --- carry the version into the plugin manifest -------------------------------
# .claude-plugin/plugin.json is Claude Code's update/cache key: it is the one
# number it reads to decide whether an installed plugin has a newer version.
# Left to be raised by hand it fell three releases behind, so every
# `/plugin install super-status` user kept being served the old release with no
# update prompt. Raised here, inside the same commit as the ledger row and the
# tag, the three can no longer disagree.
#
# A malformed write here is worse than no write — an unparseable manifest can
# stop the plugin loading for everyone — so it is staged through a temp file
# and only promoted once jq confirms the result parses.
PLUGIN_MANIFEST=".claude-plugin/plugin.json"
if [ -f "$PLUGIN_MANIFEST" ] && command -v jq >/dev/null 2>&1; then
  if jq --arg v "$next" '.version = $v' "$PLUGIN_MANIFEST" > "$PLUGIN_MANIFEST.tmp" 2>/dev/null \
     && jq empty "$PLUGIN_MANIFEST.tmp" 2>/dev/null; then
    mv "$PLUGIN_MANIFEST.tmp" "$PLUGIN_MANIFEST"
    git add "$PLUGIN_MANIFEST"
  else
    rm -f "$PLUGIN_MANIFEST.tmp"
    echo "⚠️  Could not update $PLUGIN_MANIFEST to v$next — left unchanged" >&2
  fi
fi

touch "$LOCK"
rm -f "$NOTE_FILE"
git add "$year_file"
git commit --no-verify -m "chore(version): v$next" >/dev/null 2>&1
git tag -a "v$next" -m "$SUBJECT" >/dev/null 2>&1
rm -f "$LOCK"

# --- push branch + tag --------------------------------------------------------
# A plain fast-forward push, not --force-with-lease: the default branch carries a
# ruleset with non_fast_forward, which rejects any force-push regardless of lease.
branch="$(git rev-parse --abbrev-ref HEAD)"
if git remote get-url origin >/dev/null 2>&1; then
  if git push origin "$branch" >/dev/null 2>&1; then
    git push origin "v$next" >/dev/null 2>&1
    echo "🔖 Recorded and pushed version v$next"
  else
    echo "⚠️  Recorded v$next locally but push failed (retries next commit)" >&2
  fi
else
  echo "🔖 Recorded version v$next (no remote — not pushed)"
fi
