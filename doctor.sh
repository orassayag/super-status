#!/bin/bash
# super-status doctor — verifies ~/.claude/settings.json still points statusLine
# at the super-status script, and re-patches it if something else overwrote it.

set -e

SCRIPT_PATH="$HOME/.claude/super-status/statusline.sh"
SETTINGS="$HOME/.claude/settings.json"
EXPECTED_CMD="/bin/bash ${SCRIPT_PATH}"

if [ ! -f "$SCRIPT_PATH" ]; then
    echo "✗ statusline.sh not found at $SCRIPT_PATH — re-run install first."
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "✗ jq is required for this check but isn't installed."
    exit 1
fi

if [ ! -f "$SETTINGS" ]; then
    echo "settings.json not found — creating it."
    mkdir -p "$HOME/.claude"
    echo '{}' > "$SETTINGS"
fi

current_cmd=$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null)

if [ "$current_cmd" = "$EXPECTED_CMD" ]; then
    echo "✓ settings.json already points at super-status. Nothing to do."
    exit 0
fi

cp "$SETTINGS" "${SETTINGS}.bak.$(date +%s)"
echo "Backed up existing settings.json before patching."

tmp=$(mktemp)
jq --arg cmd "$EXPECTED_CMD" '.statusLine = {"type": "command", "command": $cmd}' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"

echo "✓ Re-patched statusLine in settings.json to point at super-status."
echo "  Restart Claude Code for the change to take effect."
