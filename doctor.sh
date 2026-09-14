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
current_interval=$(jq -r '.statusLine.refreshInterval // empty' "$SETTINGS" 2>/dev/null)

if [ "$current_cmd" = "$EXPECTED_CMD" ] && [ -n "$current_interval" ]; then
    echo "✓ settings.json already points at super-status (refreshInterval: ${current_interval}s). Nothing to do."
    exit 0
fi

if [ "$current_cmd" = "$EXPECTED_CMD" ]; then
    # Without refreshInterval the script only re-runs on transcript events, so
    # the file-based Orca:/Master: line freezes the whole time the session sits
    # blocked on a tool call — the segment's main use case.
    echo "⚠ statusLine wiring is correct but refreshInterval is missing — adding it."
fi

cp "$SETTINGS" "${SETTINGS}.bak.$(date +%s)"
echo "Backed up existing settings.json before patching."

# An existing refreshInterval is preserved; 2s is the recommended default.
tmp=$(mktemp)
jq --arg cmd "$EXPECTED_CMD" \
   '.statusLine = {"type": "command", "command": $cmd, "refreshInterval": (.statusLine.refreshInterval // 2)}' \
   "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"

echo "✓ Re-patched statusLine in Claude Code settings.json to point at super-status."
echo "  Restart Claude Code for the change to take effect."

# Antigravity CLI statusLine check
AGY_DIR="$HOME/.gemini/antigravity-cli"
AGY_SETTINGS="$AGY_DIR/settings.json"
if [ -d "$AGY_DIR" ] || [ -f "$AGY_SETTINGS" ] || command -v agy >/dev/null 2>&1; then
    mkdir -p "$AGY_DIR"
    [ ! -f "$AGY_SETTINGS" ] && echo '{}' > "$AGY_SETTINGS"
    agy_cmd=$(jq -r '.statusLine.command // empty' "$AGY_SETTINGS" 2>/dev/null)
    if [ "$agy_cmd" = "$EXPECTED_CMD" ] || [ "$agy_cmd" = "$SCRIPT_PATH" ]; then
        echo "✓ Antigravity CLI settings.json already points at super-status."
    else
        cp "$AGY_SETTINGS" "${AGY_SETTINGS}.bak.$(date +%s)"
        tmp=$(mktemp)
        jq --arg cmd "$EXPECTED_CMD"            '.statusLine = {"command": $cmd, "enabled": true}'            "$AGY_SETTINGS" > "$tmp" && mv "$tmp" "$AGY_SETTINGS"
        echo "✓ Patched statusLine in Antigravity CLI settings.json."
    fi
fi
