#!/bin/bash
# super-status one-command install: copies the scripts into ~/.claude/super-status,
# makes them executable, and wires statusLine into ~/.claude/settings.json
# (via doctor.sh, which resolves $HOME itself — no placeholder paths to edit).

set -e

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="$HOME/.claude/super-status"

if ! command -v jq >/dev/null 2>&1; then
    echo "✗ jq is required. Install it first (e.g. 'brew install jq' / 'apt install jq')."
    exit 1
fi

mkdir -p "$DEST_DIR"
cp "$SRC_DIR/statusline.sh" "$DEST_DIR/statusline.sh"
cp "$SRC_DIR/doctor.sh" "$DEST_DIR/doctor.sh"
chmod +x "$DEST_DIR/statusline.sh" "$DEST_DIR/doctor.sh"
echo "✓ Installed statusline.sh and doctor.sh to $DEST_DIR"

bash "$DEST_DIR/doctor.sh"

echo ""
echo "Done. Open a NEW Claude Code session to see the statusline."
echo "Optional: create $DEST_DIR/config.json to customize (see README — try {\"preset\": \"full\"})."
