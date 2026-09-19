---
description: Declare your prepaid API credit balance — set api_credit_balance to $ARGUMENTS and stamp today's date
allowed-tools: Bash
---

Run this right after buying API credits, or any time you want to re-anchor the
`Bal` bar to the balance the Console currently shows. It writes
`api_credit_balance` and `api_credit_as_of` into
`~/.claude/super-status/config.json`; spend is then measured forward from that
date, so the bar reads as "how much of this top-up is gone".

Amount is in **USD** and is required — `/super-status:credits 102` means
$102.00. A `$` sign and thousands separators are tolerated (`$1,024.50`), since
that is how the Console renders it. An optional second argument backdates the
snapshot to a `dd/MM/yyyy` date, for a top-up you are recording after the fact.

The snapshot is stamped with the **current clock time**, not just the date,
because a balance read off the Console is true at an instant: stamping an
afternoon reading as "today" would make the bar re-subtract everything already
spent that day. A backdated snapshot gets the bare date, meaning midnight, which
is the right reading for "I topped up on the 1st".

Run this exact snippet with the Bash tool:

```bash
set -- $ARGUMENTS
RAW="${1:-}"
WHEN="${2:-}"

if [ -z "$RAW" ]; then
  echo "Usage: /super-status:credits <amount-in-usd> [dd/MM/yyyy]   e.g. /super-status:credits 102"
  exit 1
fi

# Console-shaped input: strip a currency sign and thousands separators before validating.
AMOUNT=$(printf '%s' "$RAW" | tr -d '$,')
if ! [[ "$AMOUNT" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "Invalid amount '$RAW' — expected a number of US dollars (e.g. 102 or 96.49). Aborting."
  exit 1
fi

if [ -n "$WHEN" ]; then
  if ! [[ "$WHEN" =~ ^[0-3][0-9]/[0-1][0-9]/[0-9]{4}$ ]]; then
    echo "Invalid date '$WHEN' — expected dd/MM/yyyy (e.g. 14/07/2026). Aborting."
    exit 1
  fi
  AS_OF="$WHEN"
else
  # Minute precision on purpose — see the note above about afternoon readings.
  AS_OF=$(date +"%d/%m/%Y %H:%M")
fi

CONFIG="$HOME/.claude/super-status/config.json"
mkdir -p "$(dirname "$CONFIG")"
[ -f "$CONFIG" ] || echo '{}' > "$CONFIG"

if ! jq -e . "$CONFIG" >/dev/null 2>&1; then
  echo "$CONFIG is not valid JSON — fix it first, or delete it to start fresh. Aborting."
  exit 1
fi

OLD=$(jq -r '.api_credit_balance // "<none>"' "$CONFIG")
OLD_AS_OF=$(jq -r '.api_credit_as_of // "<none>"' "$CONFIG")

# Backed up before the rewrite, same as doctor.sh does for settings.json.
cp "$CONFIG" "$CONFIG.bak"
tmp=$(mktemp) || { echo "mktemp failed"; exit 1; }
jq --argjson amount "$AMOUNT" --arg as_of "$AS_OF" \
   '.api_credit_balance = $amount | .api_credit_as_of = $as_of' \
   "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"

echo "api_credit_balance: ${OLD} -> ${AMOUNT}   (as of ${OLD_AS_OF} -> ${AS_OF})"
echo "config: $CONFIG   (previous saved to $CONFIG.bak)"
if [ -n "${ANTHROPIC_ADMIN_KEY:-}" ]; then
  echo "spend source: Admin API cost report (ANTHROPIC_ADMIN_KEY is set)"
elif command -v python3 >/dev/null 2>&1; then
  echo "spend source: local Claude Code transcripts (estimate — shown as 'est.')"
else
  echo "spend source: none — python3 is missing, so the bar will show the balance without a percentage"
fi
```

After it succeeds, tell the user the new balance is recorded and that the `Bal`
bar re-anchors on the **next** render, with the first spend figure landing once
the background refresh completes (a few seconds). Relay the `spend source` line
the snippet printed — it is what decides whether they get a bar or just the
declared figure. Do not hand-edit `config.json` yourself; if the snippet fails,
show its exact output.
