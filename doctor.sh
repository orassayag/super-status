#!/bin/bash
# super-status doctor — verifies the install is healthy and repairs what it can:
# settings.json statusLine wiring (re-patched if a plugin overwrote it),
# executable bit, config.json validity, and cache-directory permissions.

set -e

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SCRIPT_PATH="$CLAUDE_DIR/super-status/statusline.sh"
SETTINGS="$CLAUDE_DIR/settings.json"
CONFIG_FILE="$CLAUDE_DIR/super-status/config.json"
CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/super-status"
EXPECTED_CMD="/bin/bash ${SCRIPT_PATH}"

if [ ! -f "$SCRIPT_PATH" ]; then
    echo "✗ statusline.sh not found at $SCRIPT_PATH — run install.sh first."
    exit 1
fi

# --report [--width N]: a Markdown bug report built from the last real render,
# read-only. Text is masked to same-length x (path separators and spaces kept,
# so path-depth and width bugs still reproduce); numbers, timestamps, the model
# and the Claude Code version stay readable.
if [ "${1:-}" = "--report" ]; then
    report_width=""
    [ "${2:-}" = "--width" ] && report_width="${3:-}"
    last_payload="$CACHE_ROOT/last-payload.json"
    if ! command -v jq >/dev/null 2>&1; then
        echo "✗ jq is required but isn't installed."
        exit 1
    fi
    if [ ! -s "$last_payload" ]; then
        echo "✗ No render recorded yet ($last_payload). Let the statusline draw once in a Claude Code session, then retry."
        exit 1
    fi
    mask_defs='
        def walk_strings(f): if type == "object" then map_values(walk_strings(f))
            elif type == "array" then map(walk_strings(f))
            elif type == "string" then f else . end;
        def mask: if test("^[0-9][0-9:./TZ+ -]*$") then . else gsub("[^/\\\\ ]"; "x") end;'
    if ! masked_payload=$(jq "$mask_defs"'
            . as $in | walk_strings(mask)
            | if type == "object" then
                (if $in.model != null then .model = $in.model else . end)
                | (if $in.version != null then .version = $in.version else . end)
              else . end' "$last_payload" 2>/dev/null); then
        echo "✗ The last recorded input is not valid JSON, so it cannot be masked safely and is left out."
        echo "  That is itself the bug: report that Claude Code sent a statusline payload jq could not parse."
        exit 1
    fi
    masked_config="(none — defaults)"
    if [ -f "$CONFIG_FILE" ]; then
        masked_config=$(jq "$mask_defs"'
            def scrub: if type == "object" then with_entries(
                    if (.value | type) == "string" and ((.key | endswith("_path")) or (.value | test("^[/~]")))
                    then .value |= mask else .value |= scrub end)
                elif type == "array" then map(scrub) else . end;
            scrub' "$CONFIG_FILE" 2>/dev/null) || masked_config="(config.json is not valid JSON)"
    fi
    esc=$(printf '\033')
    report_cache=$(mktemp -d)
    # A throwaway cache, so the masked session never lands in the real day
    # ledger or session-diff state, nor overwrites last-payload.json itself.
    rendered=$(printf '%s' "$masked_payload" \
        | env XDG_CACHE_HOME="$report_cache" ${report_width:+COLUMNS="$report_width"} /bin/bash "$SCRIPT_PATH" 2>/dev/null \
        | sed -e "s/${esc}\[[0-9;]*m//g" -e "s/${esc}]8;;[^${esc}]*${esc}\\\\//g") || true
    rm -rf "$report_cache"
    tool_version() { "$@" 2>/dev/null | head -n 1 | tr -d '\r' || true; }
    cat <<REPORT
## super-status bug report

### Environment

- OS: $(uname -sr 2>/dev/null) (${OSTYPE:-unknown})
- bash running the statusline: $(/bin/bash -c 'echo "$BASH_VERSION"' 2>/dev/null)
- jq: $(tool_version jq --version)
- git: $(tool_version git --version)
- python3: $(tool_version python3 --version)
- statusline.sh checksum: $(cksum < "$SCRIPT_PATH" | awk '{print $1}')
- render width: ${report_width:-${COLUMNS:-unset}}

### Config (paths masked)

\`\`\`json
$masked_config
\`\`\`

### Last input (text masked, numbers kept)

\`\`\`json
$masked_payload
\`\`\`

### Rendered from the masked input

\`\`\`
$rendered
\`\`\`
REPORT
    exit 0
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
    mkdir -p "$CLAUDE_DIR"
    echo '{}' > "$SETTINGS"
fi

# A native jq.exe under Git Bash ends each line with CRLF; strip the \r so the
# comparisons below can match on Windows.
current_cmd=$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null | tr -d '\r')
current_interval=$(jq -r '.statusLine.refreshInterval // empty' "$SETTINGS" 2>/dev/null | tr -d '\r')

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

# Written back with `cat >` rather than `mv`: a settings.json that is a symlink
# (a dotfiles repo) stays a link, and the file keeps its own permissions.
# An existing refreshInterval is preserved; 2s is the recommended default.
# Git Bash gets 30s: short intervals, worse with several sessions, can leave
# it failing with "add_item ... failed, errno 1".
default_interval=2
case "${OSTYPE:-}" in msys*|cygwin*) default_interval=30 ;; esac
# MSYS2_ARG_CONV_EXCL stops Git Bash on Windows rewriting the POSIX paths in
# $cmd into C:/... form for a native jq.exe. It disables conversion for every
# argument, so the file goes in on stdin rather than as a path jq.exe can't open.
tmp=$(mktemp)
if ! MSYS2_ARG_CONV_EXCL='*' jq --arg cmd "$EXPECTED_CMD" --argjson interval "$default_interval" \
   '.statusLine = {"type": "command", "command": $cmd, "refreshInterval": (.statusLine.refreshInterval // $interval)}' \
   < "$SETTINGS" > "$tmp"; then
    rm -f "$tmp"
    echo "✗ Could not patch $SETTINGS — jq failed; the backup is untouched next to it."
    exit 1
fi
cat "$tmp" > "$SETTINGS"
rm -f "$tmp"

echo "✓ Re-patched statusLine in $SETTINGS to point at super-status."
echo "  Restart Claude Code for the change to take effect."

# Antigravity CLI statusLine check
AGY_DIR="$HOME/.gemini/antigravity-cli"
AGY_SETTINGS="$AGY_DIR/settings.json"
if [ -d "$AGY_DIR" ] || [ -f "$AGY_SETTINGS" ] || command -v agy >/dev/null 2>&1; then
    mkdir -p "$AGY_DIR"
    [ ! -f "$AGY_SETTINGS" ] && echo '{}' > "$AGY_SETTINGS"
    agy_cmd=$(jq -r '.statusLine.command // empty' "$AGY_SETTINGS" 2>/dev/null | tr -d '\r')
    if [ "$agy_cmd" = "$EXPECTED_CMD" ] || [ "$agy_cmd" = "$SCRIPT_PATH" ]; then
        echo "✓ Antigravity CLI settings.json already points at super-status."
    else
        cp "$AGY_SETTINGS" "${AGY_SETTINGS}.bak.$(date +%s)"
        tmp=$(mktemp)
        if ! MSYS2_ARG_CONV_EXCL='*' jq --arg cmd "$EXPECTED_CMD" '.statusLine = {"command": $cmd, "enabled": true}' \
            < "$AGY_SETTINGS" > "$tmp"; then
            rm -f "$tmp"
            echo "✗ Could not patch $AGY_SETTINGS — jq failed; the backup is untouched next to it."
            exit 1
        fi
        cat "$tmp" > "$AGY_SETTINGS"
        rm -f "$tmp"
        echo "✓ Patched statusLine in Antigravity CLI settings.json."
    fi
fi
