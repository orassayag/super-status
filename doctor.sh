#!/bin/bash
# super-status doctor — verifies the install is healthy and repairs what it can:
# settings.json statusLine wiring (re-patched if a plugin overwrote it),
# executable bit, config.json validity, and cache-directory permissions.

set -e

SCRIPT_PATH="$HOME/.claude/super-status/statusline.sh"
SETTINGS="$HOME/.claude/settings.json"
CONFIG_FILE="$HOME/.claude/super-status/config.json"
CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/super-status"
EXPECTED_CMD="/bin/bash ${SCRIPT_PATH}"

if [ ! -f "$SCRIPT_PATH" ]; then
    echo "✗ statusline.sh not found at $SCRIPT_PATH — run install.sh first."
    exit 1
fi

if [ ! -x "$SCRIPT_PATH" ]; then
    chmod +x "$SCRIPT_PATH"
    echo "✓ Restored the missing executable bit on statusline.sh."
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "✗ jq is required but isn't installed."
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "⚠ python3 not found — Total Tokens, Tool Calls, Activity, Agents, and Todo lines won't render."
fi

if [ -f "$CONFIG_FILE" ]; then
    if jq empty "$CONFIG_FILE" 2>/dev/null; then
        echo "✓ config.json is valid JSON."
    else
        echo "⚠ config.json is NOT valid JSON — the statusline is running on defaults and showing a warning line. Fix or delete: $CONFIG_FILE"
    fi
else
    echo "✓ No config.json — running with defaults (that's fine)."
fi

if [ -d "$CACHE_ROOT" ]; then
    _perms=$(stat -c %a "$CACHE_ROOT" 2>/dev/null || stat -f %Lp "$CACHE_ROOT" 2>/dev/null || echo "")
    if [ "$_perms" != "700" ]; then
        chmod 700 "$CACHE_ROOT"
        echo "✓ Tightened cache directory permissions to 700."
    fi
fi

# Legacy /tmp caches from pre-2.0 installs are world-readable — clear them out.
if [ -d "/tmp/super-status" ]; then
    rm -rf "/tmp/super-status"
    echo "✓ Removed the legacy world-readable /tmp/super-status cache."
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

# An existing refreshInterval is preserved; 2s is the recommended default.
tmp=$(mktemp)
jq --arg cmd "$EXPECTED_CMD" \
   '.statusLine = {"type": "command", "command": $cmd, "refreshInterval": (.statusLine.refreshInterval // 2)}' \
   "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"

echo "✓ Re-patched statusLine in settings.json to point at super-status."
echo "  Restart Claude Code for the change to take effect."
