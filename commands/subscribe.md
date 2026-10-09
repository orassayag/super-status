---
description: Renew the subscription cycle — set subscription_start_date to today (or $ARGUMENTS)
allowed-tools: Bash
---

Run this right after purchasing/renewing your Anthropic subscription. It resets
the `subscription_start_date` the `Sub` bar derives every monthly cycle from, so
the cycle restarts from the renewal day.

Target date: today by default. If `$ARGUMENTS` is a `dd/MM/yyyy` date, use that
instead (e.g. you renewed yesterday).

Run this exact snippet with the Bash tool:

```bash
ARG="$ARGUMENTS"
if [ -n "$ARG" ]; then
  if [[ "$ARG" =~ ^[0-3][0-9]/[0-1][0-9]/[0-9]{4}$ ]]; then
    NEW_DATE="$ARG"
  else
    echo "Invalid date '$ARG' — expected dd/MM/yyyy (e.g. 14/07/2026). Aborting."
    exit 1
  fi
else
  NEW_DATE=$(date +%d/%m/%Y)
fi

KEY_RE='"subscription_start_date"[[:space:]]*:[[:space:]]*"[^"]*"'
updated=""
old=""
# Match statusline.sh's resolution order: project-local CLAUDE.md, then global.
for f in "./CLAUDE.md" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/CLAUDE.md"; do
  [ -f "$f" ] || continue
  if grep -Eq "$KEY_RE" "$f"; then
    old=$(grep -Eo "$KEY_RE" "$f" | head -n1 | sed -E 's#.*"([^"]*)"$#\1#')
    tmp=$(mktemp) || { echo "mktemp failed"; exit 1; }
    sed -E "s#(\"subscription_start_date\"[[:space:]]*:[[:space:]]*\")[^\"]*(\")#\\1${NEW_DATE}\\2#" "$f" > "$tmp" && mv "$tmp" "$f"
    updated="$f"
    break
  fi
done

if [ -z "$updated" ]; then
  target="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/CLAUDE.md"
  printf '\n"subscription_start_date": "%s"\n' "$NEW_DATE" >> "$target"
  updated="$target"
  echo "No existing subscription_start_date found — added it."
fi

echo "subscription_start_date: ${old:-<none>} -> ${NEW_DATE}  (${updated})"
```

After it succeeds, tell the user the cycle now runs from `NEW_DATE` and that the
`Sub` bar reflects it on the **next** turn (statusline re-reads CLAUDE.md each
render). Do not hand-edit CLAUDE.md yourself — if the snippet fails, show its
exact output.
