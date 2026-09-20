# Releasing

Most of a release happens on its own. This file exists for the part that does
not — and because the one step that lived only in memory, raising the plugin
manifest, was forgotten for three releases in a row.

## What is automatic

`.git/hooks/post-commit` → `scripts/version-bump.sh` runs after **every** commit
and does all of this without being asked:

1. Derives the semver bump from the commit subject (Conventional Commits:
   `feat` → minor, `!` or `BREAKING CHANGE` → major, anything else → patch).
2. Prepends a plain-English row to the per-year ledger `versions/<year>.md`.
3. **Raises `version` in `.claude-plugin/plugin.json` to match**, staged through
   a temp file and promoted only once `jq` confirms the result parses.
4. Commits that as `chore(version): vX.Y.Z`, tags it `vX.Y.Z`, and pushes the
   branch and the tag.
5. `.github/workflows/release.yml` then fires on the pushed tag, pulls that
   version's row out of the ledger, and publishes a GitHub Release — failing
   loudly rather than publishing an empty one.

## What you do

### Before committing

Write `.git/version-note.md`, one plain-language bullet per line, understandable
by someone who does not read code. The hook consumes and deletes it; without it
the ledger's "Change" cell falls back to a de-jargoned commit subject, which
reads noticeably worse.

Or use the one-shot: `scripts/save.sh <plain description of the change>`.

### Every file that carries the version

| File | Who updates it |
|---|---|
| `versions/<year>.md` | The hook. **Never edit by hand** |
| `.claude-plugin/plugin.json` | The hook |
| The git tag `vX.Y.Z` | The hook |
| The GitHub Release | `release.yml`, from the ledger row |
| `CHANGELOG.md` | Nobody — it is closed at 2.5.0 and points at `versions/` |

If a new file ever needs to carry the version, it is added to
`scripts/version-bump.sh` **and** to this table, in the same change set.

### When the README gains or loses a config key

`tests/readme-options.bats` fails when the config keys `statusline.sh` reads and
the keys the README's reference block documents disagree in either direction.
That failure is the test working: the fix is a README row, not a skipped test.

## Checks before tagging matters

Nothing here blocks a release, because the version-bump hook fires on every
commit — so the discipline is at commit time, not release time:

```
shellcheck statusline.sh doctor.sh install.sh
bats tests/
```

Both run in CI on Ubuntu and macOS, plus a non-blocking Git Bash job on Windows.
