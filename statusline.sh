#!/bin/bash
# super-status — combined Claude Code statusline
# Reads JSON on stdin, writes a labeled multi-line status to stdout.
# Never crashes, never prints null/undefined/NaN — missing data is simply omitted
# (that field's label, value, and separator are all dropped together).
# All full dates are rendered dd/MM/yyyy.

set -f
export LC_NUMERIC=C

# ---------------------------------------------------------------------------
# Color constants (real ESC bytes via ANSI-C quoting, not re-interpreted later)
# ---------------------------------------------------------------------------
RESET=$'\033[0m'
CYAN=$'\033[36m'
GREEN=$'\033[32m'
MAGENTA=$'\033[35m'
GREY=$'\033[90m'
BLUE=$'\033[34m'
WHITE=$'\033[37m'
RED=$'\033[31m'
ORANGE=$'\033[38;5;208m'
YELLOW=$'\033[33m'

input=$(cat)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
jqr() { echo "$input" | jq -r "$1" 2>/dev/null; }
is_num() { [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; }

fmt_duration_ms() {
    local ms="$1"
    is_num "$ms" || { echo ""; return; }
    local s=$(( ${ms%.*} / 1000 ))
    if [ "$s" -ge 3600 ]; then
        echo "$(( s / 3600 ))h$(( (s % 3600) / 60 ))m"
    elif [ "$s" -ge 60 ]; then
        echo "$(( s / 60 ))m$(( s % 60 ))s"
    else
        echo "${s}s"
    fi
}

# Time remaining until a future epoch, formatted "3d14h10m" / "2h30m" / "45m".
# Days are only shown when >0, hours only when >0 (or days already shown).
fmt_countdown_epoch() {
    local epoch="$1"
    is_num "$epoch" || { echo ""; return; }
    local target="${epoch%.*}"
    local now_epoch
    now_epoch=$(date +%s)
    local diff=$(( target - now_epoch ))
    [ "$diff" -lt 0 ] && diff=0
    local days=$(( diff / 86400 ))
    local rem=$(( diff % 86400 ))
    local hours=$(( rem / 3600 ))
    local mins=$(( (rem % 3600) / 60 ))
    if [ "$days" -gt 0 ]; then
        echo "${days}d${hours}h${mins}m"
    elif [ "$hours" -gt 0 ]; then
        echo "${hours}h${mins}m"
    else
        echo "${mins}m"
    fi
}

# Compact k-suffixed token count, e.g. 15234 -> "15.2k", 480 -> "480".
fmt_tokens_k() {
    local n="$1"
    is_num "$n" || { echo ""; return; }
    n=${n%.*}
    if [ "$n" -ge 1000 ]; then
        awk "BEGIN{printf \"%.1fk\", $n/1000}"
    else
        echo "$n"
    fi
}

grade_for() {
    local v="$1"
    is_num "$v" || { echo ""; return; }
    awk -v v="$v" 'BEGIN{
        if (v>=90) print "A";
        else if (v>=75) print "B";
        else if (v>=60) print "C";
        else if (v>=40) print "D";
        else print "F";
    }'
}

grade_color() {
    case "$1" in
        A|B) printf '%s' "$GREEN" ;;
        C) printf '%s' "$ORANGE" ;;
        D|F) printf '%s' "$RED" ;;
        *) printf '%s' "$GREY" ;;
    esac
}

usage_color() {
    local u="$1" type="$2"
    awk -v u="$u" -v t="$type" -v red="$RED" -v orange="$ORANGE" -v green="$GREEN" 'BEGIN{
        if (u>=100){printf "%s", red; exit}
        if (t=="7d"){
            if (u>=75) printf "%s", red;
            else if (u>=50) printf "%s", orange;
            else printf "%s", green;
        } else {
            if (u>=90) printf "%s", red;
            else if (u>=70) printf "%s", orange;
            else printf "%s", green;
        }
    }'
}

# HH:MM only — used for the 5-hour reset, since it always falls within the same day.
format_time_epoch() {
    local epoch="$1"
    is_num "$epoch" || { echo ""; return; }
    date -d "@${epoch%.*}" +"%H:%M" 2>/dev/null || date -r "${epoch%.*}" +"%H:%M" 2>/dev/null || echo ""
}

# dd/MM/yyyy HH:MM — used for the 7-day reset and the bottom-line timestamp,
# since those can land on a different day than "today".
format_datetime_epoch() {
    local epoch="$1"
    is_num "$epoch" || { echo ""; return; }
    date -d "@${epoch%.*}" +"%d/%m/%Y %H:%M" 2>/dev/null || date -r "${epoch%.*}" +"%d/%m/%Y %H:%M" 2>/dev/null || echo ""
}

make_bar() {
    local pct="$1" width="${2:-20}"
    is_num "$pct" || pct=0
    [ "$pct" -lt 0 ] && pct=0
    [ "$pct" -gt 100 ] && pct=100
    local filled=$(( pct * width / 100 ))
    [ "$filled" -gt "$width" ] && filled=$width
    local empty=$(( width - filled ))
    printf "%${filled}s" | tr ' ' '#'
    printf "%${empty}s" | tr ' ' '-'
}

BAR_WIDTH=20

# Lines added/removed for one repo relative to a ref, printed as "added removed":
# tracked-file diff via --numstat (staged + unstaged + commits made after the
# ref), plus every untracked file's line count as additions. Binary files
# (numstat prints "-") are skipped. EMPTY_TREE_SHA is git's well-known constant
# empty-tree object, used as the ref for repos with no commits yet.
EMPTY_TREE_SHA=4b825dc642cb6eb9a060e54bf8d69288fbee4904

measure_repo_line_changes() {
    local repo="$1" ref="$2"
    local added=0 removed=0 a r f n
    while read -r a r _; do
        [[ "$a" =~ ^[0-9]+$ ]] && added=$(( added + a ))
        [[ "$r" =~ ^[0-9]+$ ]] && removed=$(( removed + r ))
    done < <(GIT_OPTIONAL_LOCKS=0 git -C "$repo" diff --numstat "$ref" -- 2>/dev/null)
    while IFS= read -r f; do
        [ -f "$repo/$f" ] || continue
        n=$(wc -l < "$repo/$f" 2>/dev/null | tr -d '[:space:]')
        [[ "$n" =~ ^[0-9]+$ ]] && added=$(( added + n ))
    done < <(GIT_OPTIONAL_LOCKS=0 git -C "$repo" ls-files --others --exclude-standard 2>/dev/null)
    echo "$added $removed"
}

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------
model=$(jqr '.model.display_name // empty')
project=$(jqr '.workspace.project_dir | select(. != null) | split("/") | last')
project_dir=$(jqr '.workspace.project_dir // empty')
cwd=$(jqr '.cwd // empty')
[ -z "$cwd" ] && cwd=$(jqr '.workspace.current_dir // empty')
git_root=$(git -C "${cwd:-$project_dir}" rev-parse --show-toplevel 2>/dev/null)
[ -z "$git_root" ] && git_root="${cwd:-$project_dir}"
git_branch=""
[ -n "$git_root" ] && [ -d "$git_root" ] && \
    git_branch=$(GIT_OPTIONAL_LOCKS=0 git -C "$git_root" rev-parse --abbrev-ref HEAD 2>/dev/null)
worktree=$(jqr '.workspace.git_worktree // empty')
[ "$worktree" = "null" ] && worktree=""

# Session/transcript identifiers — must be resolved before every consumer:
# the cumulative token totals, workspace line changes, Tool Calls, and
# Tools Stats sections all key their caches off these. (These previously
# lived below the token-totals section, which silently killed the Tokens:
# field — transcript_path was always empty when that block ran.)
session_id=$(jqr '.session_id // empty')
transcript_path=$(jqr '.transcript_path // empty')

# ---------------------------------------------------------------------------
# Backend detection
# OpenRouter is detected explicitly via $ANTHROPIC_BASE_URL (the stdin JSON
# doesn't distinguish backends). Subscription vs. plain API-key (Anthropic,
# z.ai, or anything else) is determined from whether `rate_limits` is present
# in the JSON — that field is only ever populated for an Anthropic subscription.
# ---------------------------------------------------------------------------
IS_OPENROUTER=0
case "$ANTHROPIC_BASE_URL" in
    *openrouter.ai*) IS_OPENROUTER=1 ;;
esac

# ---------------------------------------------------------------------------
# LOC count (60s cache per git root)
# ---------------------------------------------------------------------------
loc_value=""
if [ -n "$git_root" ] && [ -d "$git_root" ] && command -v tokei >/dev/null 2>&1; then
    _loc_dir="/tmp/super-status/loc-cache"
    mkdir -p "$_loc_dir"
    _key=$(echo "$git_root" | tr '/' '_')
    _loc_file="$_loc_dir/${_key}.txt"
    _loc_stamp="$_loc_dir/${_key}.stamp"
    _do_count=1
    if [ -f "$_loc_stamp" ]; then
        _age=$(( $(date +%s) - $(stat -c %Y "$_loc_stamp" 2>/dev/null || stat -f %m "$_loc_stamp" 2>/dev/null || echo 0) ))
        [ "$_age" -lt 60 ] && _do_count=0
    fi
    if [ "$_do_count" -eq 1 ]; then
        _raw=$(tokei "$git_root" --output json 2>/dev/null \
            | python3 -c "import json,sys; d=json.load(sys.stdin); t=d.get('Total',{}); print(t.get('code',0)+t.get('comments',0))" 2>/dev/null)
        echo "${_raw:-0}" > "$_loc_file"
        touch "$_loc_stamp"
    fi
    _total=$(cat "$_loc_file" 2>/dev/null || echo 0)
    _total=$(( ${_total:-0} + 0 ))
    if [ "$_total" -ge 1000 ]; then
        loc_value="~$(awk "BEGIN{printf \"%.1f\", $_total/1000}")k"
    elif [ "$_total" -gt 0 ]; then
        loc_value="~${_total}"
    fi
fi

# ---------------------------------------------------------------------------
# Workspace line changes (10s cache) — feeds "Lines Changes:" on line 1.
# cost.total_lines_added/removed only counts edits made by THIS session's own
# tools, so work done by sub-agents (e.g. /orca cmux panes) or inside nested
# git repos (client/ + server/ boilerplates) never showed up. Instead, every
# git repo under the workspace root (the folder VS Code / Claude Code is
# opened on) is diffed against a per-session baseline: the repo's HEAD sha
# plus its pre-existing dirty-line counts, both recorded the first time this
# session sees that repo. The rendered figure therefore covers committed,
# uncommitted, AND untracked changes made anywhere in the workspace since
# session start, regardless of which agent made them. Pre-existing dirty
# lines are subtracted back out (clamped at 0); a baseline sha that stops
# resolving (rebase, gc) re-baselines that repo. The cost-based numbers
# remain as the display fallback when no git repo is measurable, and always
# feed the Efficiency Grade, which scores this session's own tool
# productivity — not the whole workspace.
ws_added=""; ws_removed=""
ws_root="${project_dir:-${cwd:-$git_root}}"
if [ -n "$ws_root" ] && [ -d "$ws_root" ] && command -v git >/dev/null 2>&1; then
    _ws_dir="/tmp/super-status/workspace-diff-cache"
    mkdir -p "$_ws_dir"
    _ws_key="${session_id:-$(echo "$ws_root" | tr '/' '_')}"
    _ws_file="$_ws_dir/${_ws_key}.txt"
    _ws_stamp="$_ws_dir/${_ws_key}.stamp"
    _ws_do_count=1
    if [ -f "$_ws_stamp" ]; then
        _ws_age=$(( $(date +%s) - $(stat -c %Y "$_ws_stamp" 2>/dev/null || stat -f %m "$_ws_stamp" 2>/dev/null || echo 0) ))
        [ "$_ws_age" -lt 10 ] && _ws_do_count=0
    fi
    if [ "$_ws_do_count" -eq 1 ]; then
        _ws_total_added=0; _ws_total_removed=0; _ws_repo_seen=0
        while IFS= read -r _ws_git_marker; do
            _ws_repo=$(dirname "$_ws_git_marker")
            _ws_repo_seen=1
            _ws_base_file="$_ws_dir/${_ws_key}__$(echo "$_ws_repo" | tr '/' '_').base"
            _ws_base_sha=""; _ws_base_added=""; _ws_base_removed=""
            [ -f "$_ws_base_file" ] && read -r _ws_base_sha _ws_base_added _ws_base_removed < "$_ws_base_file" 2>/dev/null
            _ws_base_valid=0
            if [ "$_ws_base_sha" = "$EMPTY_TREE_SHA" ]; then
                _ws_base_valid=1
            elif [ -n "$_ws_base_sha" ] && git -C "$_ws_repo" cat-file -e "$_ws_base_sha" 2>/dev/null; then
                _ws_base_valid=1
            fi
            if [ "$_ws_base_valid" -eq 0 ]; then
                # --verify prints nothing on an unborn HEAD; a plain
                # `rev-parse HEAD` would echo the literal string "HEAD" there
                _ws_base_sha=$(GIT_OPTIONAL_LOCKS=0 git -C "$_ws_repo" rev-parse --verify HEAD 2>/dev/null)
                [ -z "$_ws_base_sha" ] && _ws_base_sha="$EMPTY_TREE_SHA"
                read -r _ws_base_added _ws_base_removed <<< "$(measure_repo_line_changes "$_ws_repo" "$_ws_base_sha")"
                echo "$_ws_base_sha $_ws_base_added $_ws_base_removed" > "$_ws_base_file"
            fi
            read -r _ws_cur_added _ws_cur_removed <<< "$(measure_repo_line_changes "$_ws_repo" "$_ws_base_sha")"
            is_num "$_ws_base_added" || _ws_base_added=0
            is_num "$_ws_base_removed" || _ws_base_removed=0
            is_num "$_ws_cur_added" || _ws_cur_added=0
            is_num "$_ws_cur_removed" || _ws_cur_removed=0
            _ws_delta_added=$(( _ws_cur_added - _ws_base_added ))
            _ws_delta_removed=$(( _ws_cur_removed - _ws_base_removed ))
            [ "$_ws_delta_added" -lt 0 ] && _ws_delta_added=0
            [ "$_ws_delta_removed" -lt 0 ] && _ws_delta_removed=0
            _ws_total_added=$(( _ws_total_added + _ws_delta_added ))
            _ws_total_removed=$(( _ws_total_removed + _ws_delta_removed ))
        done < <(find "$ws_root" -maxdepth 4 \( -name node_modules -o -name .venv -o -name vendor \) -prune -o -name .git -print 2>/dev/null)
        if [ "$_ws_repo_seen" -eq 1 ]; then
            echo "$_ws_total_added $_ws_total_removed" > "$_ws_file"
        else
            : > "$_ws_file"
        fi
        touch "$_ws_stamp"
    fi
    read -r ws_added ws_removed < "$_ws_file" 2>/dev/null
    is_num "$ws_added" && is_num "$ws_removed" || { ws_added=""; ws_removed=""; }
fi

# ---------------------------------------------------------------------------
# Context window % + bar + tokens
# ---------------------------------------------------------------------------
pct=$(jqr '.context_window.used_percentage // empty')
if ! is_num "$pct"; then
    window_size=$(jqr '.context_window.context_window_size // 200000')
    it=$(jqr '.context_window.current_usage.input_tokens // 0')
    cc=$(jqr '.context_window.current_usage.cache_creation_input_tokens // 0')
    cr=$(jqr '.context_window.current_usage.cache_read_input_tokens // 0')
    is_num "$window_size" || window_size=200000
    total=$(( ${it:-0} + ${cc:-0} + ${cr:-0} ))
    pct=$(( window_size > 0 ? total * 100 / window_size : 0 ))
fi
pct=${pct%.*}
is_num "$pct" || pct=0
[ "$pct" -lt 0 ] && pct=0
[ "$pct" -gt 100 ] && pct=100
ctx_bar=$(make_bar "$pct" "$BAR_WIDTH")
if [ "$pct" -ge 90 ]; then pct_color="$RED"
elif [ "$pct" -ge 70 ]; then pct_color="$ORANGE"
else pct_color="$GREEN"
fi

token_input=$(jqr '.context_window.current_usage.input_tokens // 0')
token_cc=$(jqr '.context_window.current_usage.cache_creation_input_tokens // 0')
token_cr=$(jqr '.context_window.current_usage.cache_read_input_tokens // 0')
token_max=$(jqr '.context_window.context_window_size // 200000')
is_num "$token_max" || token_max=200000
token_total=$(( ${token_input:-0} + ${token_cc:-0} + ${token_cr:-0} ))
token_used_k=$(( token_total / 1000 ))
token_max_k=$(( token_max / 1000 ))

# Cumulative session totals (separate from the current-context numbers above,
# which reset after /compact — these keep growing for the whole session).
#
# NOTE: neither total_input_tokens nor total_output_tokens is trusted
# straight from Claude Code's own JSON. total_output_tokens reflects only
# the last exchange's output, not a running total, so trusting it directly
# makes the "out" number visibly drop turn to turn instead of accumulating.
# total_input_tokens is also unreliable early on — it (like rate_limits)
# stays null/absent until Claude Code has completed at least one real API
# call in the session. Instead we derive BOTH ourselves by summing every
# assistant message's usage fields out of the transcript JSONL — input
# tokens as input_tokens + cache_creation_input_tokens + cache_read_input_tokens
# (mirroring how the current-context total on line 3 is built), output
# tokens as output_tokens — cached together by mtime like the other
# transcript-derived fields below.
session_total_input=""
session_total_output=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    _sto_dir="/tmp/super-status/tokentotals-cache"
    mkdir -p "$_sto_dir"
    _sto_key="${session_id:-$(echo "$transcript_path" | tr '/' '_')}"
    _sto_file="$_sto_dir/${_sto_key}.txt"
    _sto_stamp="$_sto_dir/${_sto_key}.mtime"
    _sto_src_mtime=$(stat -c %Y "$transcript_path" 2>/dev/null || stat -f %m "$transcript_path" 2>/dev/null || echo 0)
    _sto_cached_mtime=$(cat "$_sto_stamp" 2>/dev/null || echo -1)
    if [ "$_sto_src_mtime" != "$_sto_cached_mtime" ]; then
        _sto_value=$(python3 -c "
import json, sys

path = sys.argv[1]
total_in = 0
total_out = 0
try:
    with open(path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            msg = obj.get('message') or {}
            if msg.get('role') != 'assistant':
                continue
            usage = msg.get('usage') or {}
            inp = usage.get('input_tokens')
            cc = usage.get('cache_creation_input_tokens')
            cr = usage.get('cache_read_input_tokens')
            out = usage.get('output_tokens')
            if isinstance(inp, (int, float)):
                total_in += inp
            if isinstance(cc, (int, float)):
                total_in += cc
            if isinstance(cr, (int, float)):
                total_in += cr
            if isinstance(out, (int, float)):
                total_out += out
except Exception:
    pass
print(f'{int(total_in)} {int(total_out)}')
" "$transcript_path" 2>/dev/null)
        echo "${_sto_value:-0 0}" > "$_sto_file"
        echo "$_sto_src_mtime" > "$_sto_stamp"
    fi
    read -r session_total_input session_total_output < "$_sto_file" 2>/dev/null
    is_num "$session_total_input" || session_total_input=""
    is_num "$session_total_output" || session_total_output=""
fi

# ---------------------------------------------------------------------------
# Thinking (API) time, version, line diff, cost, session duration
# ---------------------------------------------------------------------------
api_ms=$(jqr '.cost.total_api_duration_ms // empty')
thinking_value=""
if is_num "$api_ms" && [ "${api_ms%.*}" -gt 0 ]; then
    thinking_value=$(fmt_duration_ms "$api_ms")
fi

cc_version=$(jqr '.version // empty')

lines_added=$(jqr '.cost.total_lines_added // 0')
lines_removed=$(jqr '.cost.total_lines_removed // 0')
la=${lines_added%.*}; [ -z "$la" ] && la=0
lr=${lines_removed%.*}; [ -z "$lr" ] && lr=0

cost_usd=$(jqr '.cost.total_cost_usd // empty')

dur_ms=$(jqr '.cost.total_duration_ms // empty')
session_dur_value=""
is_num "$dur_ms" && session_dur_value=$(fmt_duration_ms "$dur_ms")

# Subscription vs API-key/OpenRouter detection (rate_limits presence is the signal)
five_util_probe=$(jqr '.rate_limits.five_hour.used_percentage // empty')
seven_util_probe=$(jqr '.rate_limits.seven_day.used_percentage // empty')
IS_SUBSCRIPTION=0
is_num "$five_util_probe" && is_num "$seven_util_probe" && IS_SUBSCRIPTION=1

# ---------------------------------------------------------------------------
# Line 1 — Model | Repo | Branch | Worktree | Lines Changes | Claude Version
# ---------------------------------------------------------------------------
line1=""
if [ -n "$model" ]; then
    line1="${WHITE}Model:${RESET} ${CYAN}${model}${RESET}"
fi
if [ -n "$project" ]; then
    [ -n "$line1" ] && line1="${line1} | "
    line1="${line1}${WHITE}Repo:${RESET} ${GREEN}${project}${RESET}"
fi
if [ -n "$git_branch" ]; then
    [ -n "$line1" ] && line1="${line1} | "
    line1="${line1}${WHITE}Branch:${RESET} ${MAGENTA}${git_branch}${RESET}"
fi
if [ -n "$worktree" ]; then
    [ -n "$line1" ] && line1="${line1} | "
    line1="${line1}${WHITE}Worktree:${RESET} ${MAGENTA}${worktree}${RESET}"
fi
# Workspace-wide git figures preferred; the session's own cost figures are
# the fallback when no git repo was measurable (see the workspace section).
lines_changed_added="$la"; lines_changed_removed="$lr"
if is_num "$ws_added" && is_num "$ws_removed"; then
    lines_changed_added="$ws_added"; lines_changed_removed="$ws_removed"
fi
if [ "$lines_changed_added" -gt 0 ] || [ "$lines_changed_removed" -gt 0 ]; then
    [ -n "$line1" ] && line1="${line1} | "
    line1="${line1}${WHITE}Lines Changes:${RESET} ${GREEN}+${lines_changed_added}${RESET} ${RED}-${lines_changed_removed}${RESET}"
fi
if [ -n "$cc_version" ]; then
    [ -n "$line1" ] && line1="${line1} | "
    line1="${line1}${WHITE}Claude Version:${RESET} ${GREY}v${cc_version}${RESET}"
fi

# ---------------------------------------------------------------------------
# Line 2 — mode-dependent:
# subscription mode -> Sessions: 5h / Nd usage with reset time-left + clock
#                       (Nd = actual days remaining until the weekly window
#                       resets, computed live — not hardcoded to "7d", since
#                       it's a rolling window). Bars are colored to match
#                       their usage color (green/orange/red), not a flat blue.
# OpenRouter mode     -> live Balance bar from /api/v1/credits, same coloring
# other API-key mode  -> omitted (no reliable balance source exists)
# ---------------------------------------------------------------------------
line2=""
if [ "$IS_SUBSCRIPTION" -eq 1 ]; then
    five_util="$five_util_probe"
    five_reset=$(jqr '.rate_limits.five_hour.resets_at // empty')
    seven_util="$seven_util_probe"
    seven_reset=$(jqr '.rate_limits.seven_day.resets_at // empty')

    five_pct=${five_util%.*}; is_num "$five_pct" || five_pct=0
    seven_pct=${seven_util%.*}; is_num "$seven_pct" || seven_pct=0

    five_color=$(usage_color "$five_pct" "5h")
    seven_color=$(usage_color "$seven_pct" "7d")

    five_bar=$(make_bar "$five_pct" "$BAR_WIDTH")
    seven_bar=$(make_bar "$seven_pct" "$BAR_WIDTH")

    five_reset_clock=$(format_time_epoch "$five_reset")
    five_reset_countdown=$(fmt_countdown_epoch "$five_reset")
    seven_reset_clock=$(format_datetime_epoch "$seven_reset")
    seven_reset_countdown=$(fmt_countdown_epoch "$seven_reset")

    # Dynamic day-count label for the weekly window: the reset is a rolling
    # window, not always a literal 7 days out, so we compute the actual
    # number of days remaining from "now" to resets_at rather than hardcoding "7d".
    seven_days_label="7d"
    seven_reset_int=${seven_reset%.*}
    if is_num "$seven_reset_int"; then
        now_epoch=$(date +%s)
        _diff=$(( seven_reset_int - now_epoch ))
        [ "$_diff" -lt 0 ] && _diff=0
        # Ceiling division: partial days round up (e.g. 18h left -> "1d", 4.2 days -> "5d")
        _days_left=$(( (_diff + 86399) / 86400 ))
        seven_days_label="${_days_left}d"
    fi

    line2="${WHITE}Sessions:${RESET} ${YELLOW}5h:${RESET} ${five_color}${five_pct}%${RESET} ${five_color}[${five_bar}]${RESET}"
    if [ -n "$five_reset_countdown" ] && [ -n "$five_reset_clock" ]; then
        line2="${line2} ${GREY}(Reset: ${five_reset_countdown} [${five_reset_clock}])${RESET}"
    elif [ -n "$five_reset_clock" ]; then
        line2="${line2} ${GREY}(Reset: ${five_reset_clock})${RESET}"
    fi

    line2="${line2} | ${YELLOW}${seven_days_label}:${RESET} ${seven_color}${seven_pct}%${RESET} ${seven_color}[${seven_bar}]${RESET}"
    if [ -n "$seven_reset_countdown" ] && [ -n "$seven_reset_clock" ]; then
        line2="${line2} ${GREY}(Reset: ${seven_reset_countdown} [${seven_reset_clock}])${RESET}"
    elif [ -n "$seven_reset_clock" ]; then
        line2="${line2} ${GREY}(Reset: ${seven_reset_clock})${RESET}"
    fi

elif [ "$IS_OPENROUTER" -eq 1 ] && [ -n "$OPENROUTER_API_KEY" ] && command -v curl >/dev/null 2>&1; then
    # Live balance from OpenRouter, 60s cache, timeout-bounded so a slow/down
    # API never blocks the render. Both total and remaining are read live —
    # never hardcoded — so top-ups are reflected automatically.
    _or_dir="/tmp/super-status/openrouter-cache"
    mkdir -p "$_or_dir"
    _or_key=$(echo "$OPENROUTER_API_KEY" | md5sum 2>/dev/null | cut -d' ' -f1)
    [ -z "$_or_key" ] && _or_key="default"
    _or_file="$_or_dir/${_or_key}.json"
    _or_stamp="$_or_dir/${_or_key}.stamp"
    _or_do_fetch=1
    if [ -f "$_or_stamp" ]; then
        _or_age=$(( $(date +%s) - $(stat -c %Y "$_or_stamp" 2>/dev/null || stat -f %m "$_or_stamp" 2>/dev/null || echo 0) ))
        [ "$_or_age" -lt 60 ] && _or_do_fetch=0
    fi
    if [ "$_or_do_fetch" -eq 1 ]; then
        _or_resp=$(curl -s --max-time 3 "https://openrouter.ai/api/v1/credits" \
            -H "Authorization: Bearer ${OPENROUTER_API_KEY}" 2>/dev/null)
        if [ -n "$_or_resp" ]; then
            echo "$_or_resp" > "$_or_file"
            touch "$_or_stamp"
        fi
    fi
    if [ -f "$_or_file" ]; then
        or_total=$(jq -r '.data.total_credits // empty' "$_or_file" 2>/dev/null)
        or_used=$(jq -r '.data.total_usage // empty' "$_or_file" 2>/dev/null)
        if is_num "$or_total" && is_num "$or_used"; then
            or_remaining=$(awk "BEGIN{printf \"%.2f\", $or_total - $or_used}")
            or_used_pct=$(awk "BEGIN{ if ($or_total > 0) printf \"%.0f\", ($or_used/$or_total)*100; else print 0 }")
            or_bar=$(make_bar "$or_used_pct" "$BAR_WIDTH")
            or_color=$(usage_color "$or_used_pct" "5h")
            line2="${WHITE}Balance:${RESET} ${or_color}\$$(printf "%.2f" "$or_remaining") / \$$(printf "%.2f" "$or_total")${RESET} ${or_color}[${or_bar}]${RESET} ${or_color}${or_used_pct}% used${RESET}"
        fi
    fi
fi
# other API-key mode (Anthropic pay-as-you-go, z.ai, etc.): line2 stays empty,
# omitted cleanly below — no reliable balance source exists for these.

# ---------------------------------------------------------------------------
# Line 3 — Context % + bar + tokens | Cost | session token totals
# ---------------------------------------------------------------------------
line3="${WHITE}Context:${RESET} ${pct_color}${pct}%${RESET} ${pct_color}[${ctx_bar}]${RESET} ${GREY}(${token_used_k}k/${token_max_k}k)${RESET}"
if is_num "$cost_usd"; then
    line3="${line3} | ${WHITE}Cost:${RESET} ${YELLOW}\$$(printf "%.2f" "$cost_usd")${RESET}"
fi
if is_num "$session_total_input" && is_num "$session_total_output"; then
    _in_fmt=$(fmt_tokens_k "$session_total_input")
    _out_fmt=$(fmt_tokens_k "$session_total_output")
    line3="${line3} | ${WHITE}Tokens:${RESET} ${GREY}${_in_fmt} in / ${_out_fmt} out${RESET}"
fi

# ---------------------------------------------------------------------------
# Line 4 — Lines of code | Total Session Time | Total thinking time
# ---------------------------------------------------------------------------
line4=""
if [ -n "$loc_value" ]; then
    line4="${WHITE}Lines of code in project:${RESET} ${GREY}${loc_value}${RESET}"
fi
if [ -n "$session_dur_value" ]; then
    [ -n "$line4" ] && line4="${line4} | "
    line4="${line4}${WHITE}Total Session Time:${RESET} ${GREY}${session_dur_value}${RESET}"
fi
if [ -n "$thinking_value" ]; then
    [ -n "$line4" ] && line4="${line4} | "
    line4="${line4}${WHITE}Total thinking time:${RESET} ${GREY}${thinking_value}${RESET}"
fi

# ---------------------------------------------------------------------------
# Line 5 — ContextQ grade | Eff grade | Tool Calls
# ---------------------------------------------------------------------------
total_for_ratio=$(( ${token_input:-0} + ${token_cc:-0} + ${token_cr:-0} ))
ctxq_grade=""; cache_ratio=""
if [ "$total_for_ratio" -gt 0 ]; then
    cache_ratio=$(awk "BEGIN{printf \"%.0f\", (${token_cr:-0} / $total_for_ratio) * 100}" 2>/dev/null)
    ctxq_grade=$(grade_for "$cache_ratio")
fi

# Tool call count — parsed from the transcript JSONL, cached by session_id + mtime
tool_count=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    _ts_dir="/tmp/super-status/tools-cache"
    mkdir -p "$_ts_dir"
    _ts_key="${session_id:-$(echo "$transcript_path" | tr '/' '_')}"
    _ts_file="$_ts_dir/${_ts_key}.count"
    _ts_stamp="$_ts_dir/${_ts_key}.mtime"
    _src_mtime=$(stat -c %Y "$transcript_path" 2>/dev/null || stat -f %m "$transcript_path" 2>/dev/null || echo 0)
    _cached_mtime=$(cat "$_ts_stamp" 2>/dev/null || echo -1)
    if [ "$_src_mtime" != "$_cached_mtime" ]; then
        # grep -c still prints "0" to stdout on zero matches, but exits 1 (its
        # "no match" signal) — so `grep -c ... || echo 0` would run BOTH and
        # capture "0\n0" into the variable. Capture once, then validate instead.
        _count=$(grep -c '"type":"tool_use"' "$transcript_path" 2>/dev/null)
        is_num "$_count" || _count=0
        echo "$_count" > "$_ts_file"
        echo "$_src_mtime" > "$_ts_stamp"
    fi
    # head -n1 also self-heals any cache file left corrupted by the old bug
    tool_count=$(head -n1 "$_ts_file" 2>/dev/null)
    is_num "$tool_count" || tool_count=0
    tool_count=$(( tool_count + 0 ))
fi

eff_grade=""; eff_score=""
if [ -n "$tool_count" ] && [ "$tool_count" -gt 0 ]; then
    lines_changed=$(( la + lr ))
    ratio=$(awk "BEGIN{printf \"%.2f\", $lines_changed / $tool_count}" 2>/dev/null)
    eff_score=$(awk "BEGIN{s=$ratio*40; if(s>100) s=100; printf \"%.0f\", s}" 2>/dev/null)
    eff_grade=$(grade_for "$eff_score")
fi

line5=""
if [ -n "$ctxq_grade" ]; then
    ctxq_color=$(grade_color "$ctxq_grade")
    line5="${WHITE}Context Efficiency Grade (A–F):${RESET} ${ctxq_color}${ctxq_grade}(${cache_ratio})${RESET}"
fi
if [ -n "$eff_grade" ]; then
    eff_color=$(grade_color "$eff_grade")
    [ -n "$line5" ] && line5="${line5} | "
    line5="${line5}${WHITE}Efficiency Grade (A–F):${RESET} ${eff_color}${eff_grade}(${eff_score})${RESET}"
fi

# ---------------------------------------------------------------------------
# Line 6 — Tools Stats: call counts per tool category this session, parsed
# from the transcript JSONL and cached by mtime. Bash calls are categorized
# by their underlying command (npm, git, pnpm, ...) rather than lumped
# together as "Bash", so you can see what you're actually running. All
# mcp__* calls are folded into one "mcp" bucket regardless of server/tool.
# Only the top TOOLS_STATS_TOP_N categories are shown individually, ranked
# by count; everything else is summed into a trailing "other" bucket (shown
# even at 0, so the shape of the line stays stable as usage shifts).
# ---------------------------------------------------------------------------
TOOLS_STATS_TOP_N=5
tools_stats=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    _tst_dir="/tmp/super-status/toolstats-cache"
    mkdir -p "$_tst_dir"
    _tst_key="${session_id:-$(echo "$transcript_path" | tr '/' '_')}"
    _tst_file="$_tst_dir/${_tst_key}.txt"
    _tst_stamp="$_tst_dir/${_tst_key}.mtime"
    _tst_src_mtime=$(stat -c %Y "$transcript_path" 2>/dev/null || stat -f %m "$transcript_path" 2>/dev/null || echo 0)
    _tst_cached_mtime=$(cat "$_tst_stamp" 2>/dev/null || echo -1)
    if [ "$_tst_src_mtime" != "$_tst_cached_mtime" ]; then
        _tst_value=$(python3 -c "
import json, sys
from collections import Counter

path = sys.argv[1]
top_n = int(sys.argv[2])
counts = Counter()

def bash_category(cmd):
    if not isinstance(cmd, str):
        return 'bash'
    cmd = cmd.strip()
    if not cmd:
        return 'bash'
    first = cmd.split()[0]
    # drop a path prefix, e.g. /usr/bin/git -> git
    first = first.rstrip(':').split('/')[-1]
    return first.lower() if first else 'bash'

try:
    with open(path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            content = (obj.get('message') or {}).get('content')
            if not isinstance(content, list):
                continue
            for block in content:
                if not (isinstance(block, dict) and block.get('type') == 'tool_use'):
                    continue
                name = block.get('name') or ''
                if name.startswith('mcp__'):
                    counts['mcp'] += 1
                elif name.lower() == 'bash':
                    inp = block.get('input') or {}
                    counts[bash_category(inp.get('command'))] += 1
                else:
                    counts[name.lower()] += 1
except Exception:
    pass

# Rank by count desc, then name asc for stable ordering on ties.
ranked = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))
top = ranked[:top_n]
other = sum(c for _, c in ranked[top_n:])
total_all = sum(counts.values())

print(f'TOTAL {total_all}')
for name, c in top:
    print(f'{name} {c}')
print(f'other {other}')
" "$transcript_path" "$TOOLS_STATS_TOP_N" 2>/dev/null)
        printf '%s\n' "$_tst_value" > "$_tst_file"
        echo "$_tst_src_mtime" > "$_tst_stamp"
    fi

    tools_stats_total=""
    if [ -s "$_tst_file" ]; then
        while IFS=' ' read -r _cat _cnt; do
            [ -z "$_cat" ] && continue
            is_num "$_cnt" || _cnt=0
            if [ "$_cat" = "TOTAL" ]; then
                tools_stats_total="$_cnt"
                continue
            fi
            [ -n "$tools_stats" ] && tools_stats="${tools_stats} | "
            tools_stats="${tools_stats}${CYAN}${_cat}:${RESET} ${YELLOW}${_cnt}${RESET}"
        done < "$_tst_file"
    fi
fi

line6=""
if [ -n "$tools_stats" ]; then
    if [ -n "$tools_stats_total" ]; then
        line6="${WHITE}Tools Stats (${tools_stats_total}):${RESET} ${tools_stats}"
    else
        line6="${WHITE}Tools Stats:${RESET} ${tools_stats}"
    fi
fi

# ---------------------------------------------------------------------------
# Output — only print lines that actually have content.
# Uses %s (data), never re-parses content as a format string, so literal
# '%' characters anywhere in the values can never break printf.
# ---------------------------------------------------------------------------
[ -n "$line1" ] && printf '%s\n' "$line1"
[ -n "$line2" ] && printf '%s\n' "$line2"
[ -n "$line3" ] && printf '%s\n' "$line3"
[ -n "$line4" ] && printf '%s\n' "$line4"
[ -n "$line5" ] && printf '%s\n' "$line5"
[ -n "$line6" ] && printf '%s\n' "$line6"

exit 0
