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
BOLD_RED=$'\033[1;31m'
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

# dd/MM/yyyy only — used for the subscription cycle renewal date.
format_date_epoch() {
    local epoch="$1"
    is_num "$epoch" || { echo ""; return; }
    date -d "@${epoch%.*}" +"%d/%m/%Y" 2>/dev/null || date -r "${epoch%.*}" +"%d/%m/%Y" 2>/dev/null || echo ""
}

# dd/MM/yyyy -> epoch seconds; prints nothing on invalid input.
# Not `date -d "14/07/2026"`: BSD date has no GNU-style -d, and GNU date reads
# slash dates as MM/DD — so a BSD/GNU dual-command fallback on an unambiguous
# format is used instead, same pattern as the stat calls elsewhere.
# Midnight is passed explicitly because BSD `date -j -f` fills unspecified
# time fields from the current clock, which would drift the epoch within a day.
# Round-trip check: BSD strptime silently normalizes 31/02 -> 03/03, so the
# epoch is re-formatted and must match the input exactly (GNU date rejects
# 2026-02-31 outright, so its branch never lies).
parse_subscription_date() {
    local _d="$1" _day _month _year _rest _epoch _back
    [[ "$_d" =~ ^[0-3][0-9]/[0-1][0-9]/[0-9]{4}$ ]] || return
    _day="${_d%%/*}"; _rest="${_d#*/}"
    _month="${_rest%%/*}"; _year="${_rest#*/}"
    _epoch=$(date -j -f "%d/%m/%Y %H:%M:%S" "$_d 00:00:00" +%s 2>/dev/null \
          || date -d "${_year}-${_month}-${_day} 00:00:00" +%s 2>/dev/null) || return
    _back=$(date -r "$_epoch" +%d/%m/%Y 2>/dev/null \
         || date -d "@${_epoch}" +%d/%m/%Y 2>/dev/null)
    [ "$_back" = "$_d" ] && printf '%s' "$_epoch"
}

days_in_month() {
    local m=$(( 10#$1 )) y=$(( 10#$2 ))
    case "$m" in
        1|3|5|7|8|10|12) echo 31 ;;
        4|6|9|11) echo 30 ;;
        2)
            if [ $(( y % 4 )) -eq 0 ] && { [ $(( y % 100 )) -ne 0 ] || [ $(( y % 400 )) -eq 0 ]; }; then
                echo 29
            else
                echo 28
            fi
            ;;
        *) echo "" ;;
    esac
}

# day month year + N calendar months -> epoch of the resulting date at
# midnight. Calendar months, not fixed 30-day blocks — "14/07 -> 14/08" is
# same day next month. A start day missing from the target month (31/01 ->
# February) clamps to that month's last day.
add_months_epoch() {
    local day=$(( 10#$1 )) month=$(( 10#$2 )) year=$(( 10#$3 )) n="$4"
    local total_month=$(( year * 12 + month - 1 + n ))
    local target_year=$(( total_month / 12 ))
    local target_month=$(( total_month % 12 + 1 ))
    local max_day
    max_day=$(days_in_month "$target_month" "$target_year")
    [ -n "$max_day" ] || return
    [ "$day" -gt "$max_day" ] && day=$max_day
    parse_subscription_date "$(printf '%02d/%02d/%04d' "$day" "$target_month" "$target_year")"
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
# the cumulative token totals, workspace line changes, and Tool Calls
# sections all key their caches off these. (These previously
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
# Subscription renewal cycle — Anthropic exposes no billing/renewal date in
# the stdin JSON, so the start date is read from a user-declared
#   "subscription_start_date": "dd/MM/yyyy"
# line in CLAUDE.md — local project file first, then the global one. Local
# wins; a found-but-invalid value short-circuits (does NOT fall through to
# global). Subscription mode only: API-key/OpenRouter users have no cycle to
# track, so the whole feature (file reads, warning, bar) is inert for them.
# ---------------------------------------------------------------------------
SUBSCRIPTION_DATE_STATE=""
SUBSCRIPTION_START_RAW=""

resolve_subscription_start_date() {
    local _file _raw
    for _file in "${git_root:+$git_root/CLAUDE.md}" "$HOME/.claude/CLAUDE.md"; do
        [ -n "$_file" ] && [ -f "$_file" ] || continue
        _raw=$(grep -o '"subscription_start_date"[[:space:]]*:[[:space:]]*"[^"]*"' "$_file" 2>/dev/null | head -n1)
        [ -z "$_raw" ] && continue
        _raw=$(printf '%s' "$_raw" | sed 's/.*:[[:space:]]*"\([^"]*\)"$/\1/')
        if [ -n "$(parse_subscription_date "$_raw")" ]; then
            SUBSCRIPTION_DATE_STATE="valid"
            SUBSCRIPTION_START_RAW="$_raw"
        else
            SUBSCRIPTION_DATE_STATE="invalid"
        fi
        return
    done
    SUBSCRIPTION_DATE_STATE="missing"
}

subscription_warning_line=""
subscription_line=""
if [ "$IS_SUBSCRIPTION" -eq 1 ]; then
    resolve_subscription_start_date
    case "$SUBSCRIPTION_DATE_STATE" in
        missing)
            subscription_warning_line="${BOLD_RED}SUBSCRIPTION START DATE IS MISSING - ADD IT TO THE CLAUDE.MD: \"subscription_start_date\": \"dd/MM/yyyy\"${RESET}"
            ;;
        invalid)
            subscription_warning_line="${BOLD_RED}SUBSCRIPTION START DATE IS INVALID - ADD IT TO THE CLAUDE.MD: \"subscription_start_date\": \"dd/MM/yyyy\"${RESET}"
            ;;
        valid)
            _sub_day="${SUBSCRIPTION_START_RAW%%/*}"
            _sub_rest="${SUBSCRIPTION_START_RAW#*/}"
            _sub_month="${_sub_rest%%/*}"; _sub_year="${_sub_rest#*/}"
            _sub_now=$(date +%s)
            # Whole-month distance gives a starting guess one cycle early;
            # walking forward from there keeps the loop to a couple of
            # add_months_epoch calls no matter how old the start date is.
            _sub_n=$(( ($(date +%Y) * 12 + 10#$(date +%m)) - (10#$_sub_year * 12 + 10#$_sub_month) - 1 ))
            [ "$_sub_n" -lt 0 ] && _sub_n=0
            _cycle_end=$(add_months_epoch "$_sub_day" "$_sub_month" "$_sub_year" $(( _sub_n + 1 )))
            while [ -n "$_cycle_end" ] && [ "$_cycle_end" -le "$_sub_now" ]; do
                _sub_n=$(( _sub_n + 1 ))
                _cycle_end=$(add_months_epoch "$_sub_day" "$_sub_month" "$_sub_year" $(( _sub_n + 1 )))
            done
            _cycle_start=$(add_months_epoch "$_sub_day" "$_sub_month" "$_sub_year" "$_sub_n")
            if is_num "$_cycle_start" && is_num "$_cycle_end" && [ "$_cycle_end" -gt "$_cycle_start" ]; then
                _sub_pct=$(( (_sub_now - _cycle_start) * 100 / (_cycle_end - _cycle_start) ))
                [ "$_sub_pct" -lt 0 ] && _sub_pct=0
                [ "$_sub_pct" -gt 100 ] && _sub_pct=100
                # Ceiling division, same rounding convention as the weekly reset label
                _sub_days_left=$(( (_cycle_end - _sub_now + 86399) / 86400 ))
                [ "$_sub_days_left" -lt 0 ] && _sub_days_left=0
                _sub_bar=$(make_bar "$_sub_pct" "$BAR_WIDTH")
                _sub_reset_date=$(format_date_epoch "$_cycle_end")
                # Informational progress coloring, not a rate-limit warning:
                # green early, orange mid-cycle, red in the final ~2 days.
                if [ "$_sub_days_left" -le 2 ]; then _sub_color="$RED"
                elif [ "$_sub_pct" -ge 50 ]; then _sub_color="$ORANGE"
                else _sub_color="$GREEN"
                fi
                subscription_line="${WHITE}Subscription:${RESET} ${_sub_color}${_sub_pct}%${RESET} ${_sub_color}[${_sub_bar}]${RESET} ${GREY}(Reset: ${_sub_days_left}d [${_sub_reset_date}])${RESET}"
            fi
            ;;
    esac
fi

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
    # On subscription mode this figure is computed at standard API list rates
    # and has no relationship to the flat monthly fee actually billed — it's
    # an API-equivalent estimate. On API-key/OpenRouter mode it IS real spend.
    cost_label="Cost:"
    [ "$IS_SUBSCRIPTION" -eq 1 ] && cost_label="Cost (est.):"
    line3="${line3} | ${WHITE}${cost_label}${RESET} ${YELLOW}\$$(printf "%.2f" "$cost_usd")${RESET}"
fi
if is_num "$session_total_input" && is_num "$session_total_output"; then
    _in_fmt=$(fmt_tokens_k "$session_total_input")
    _out_fmt=$(fmt_tokens_k "$session_total_output")
    line3="${line3} | ${WHITE}Total Tokens:${RESET} ${GREY}${_in_fmt} in / ${_out_fmt} out${RESET}"
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
# Shared transcript pass (feeds lines 5 and 6) — every tool_use block in the
# transcript JSONL is mapped into exactly one of six semantic buckets:
#   Skills   -> Skill
#   Code     -> Edit / Write / MultiEdit / NotebookEdit (edit-capable tools)
#   Commands -> Bash (no per-command split — that open-ended list is what
#               made the old Tools Stats line unstable)
#   Read     -> Read / Glob / Grep / LS
#   MCP Call -> any mcp__* prefixed tool, regardless of server
#   Other    -> guaranteed fallback, so nothing silently disappears
# The bucket sum always equals the printed total by construction. The Code
# bucket doubles as the Efficiency Grade denominator on line 5. Cached by
# session_id + transcript mtime, same as the other transcript-derived fields.
# ---------------------------------------------------------------------------
tool_calls_total=""
bucket_skills=""; bucket_code=""; bucket_commands=""
bucket_read=""; bucket_mcp=""; bucket_other=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    _tst_dir="/tmp/super-status/toolcalls-cache"
    mkdir -p "$_tst_dir"
    _tst_key="${session_id:-$(echo "$transcript_path" | tr '/' '_')}"
    _tst_file="$_tst_dir/${_tst_key}.txt"
    _tst_stamp="$_tst_dir/${_tst_key}.mtime"
    _tst_src_mtime=$(stat -c %Y "$transcript_path" 2>/dev/null || stat -f %m "$transcript_path" 2>/dev/null || echo 0)
    _tst_cached_mtime=$(cat "$_tst_stamp" 2>/dev/null || echo -1)
    if [ "$_tst_src_mtime" != "$_tst_cached_mtime" ]; then
        _tst_value=$(python3 -c "
import json, sys

path = sys.argv[1]
buckets = {'SKILLS': 0, 'CODE': 0, 'COMMANDS': 0, 'READ': 0, 'MCP': 0, 'OTHER': 0}
code_tools = {'edit', 'write', 'multiedit', 'notebookedit'}
read_tools = {'read', 'glob', 'grep', 'ls'}

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
                low = name.lower()
                if name.startswith('mcp__'):
                    buckets['MCP'] += 1
                elif low == 'skill':
                    buckets['SKILLS'] += 1
                elif low in code_tools:
                    buckets['CODE'] += 1
                elif low == 'bash':
                    buckets['COMMANDS'] += 1
                elif low in read_tools:
                    buckets['READ'] += 1
                else:
                    buckets['OTHER'] += 1
except Exception:
    pass

print(f'TOTAL {sum(buckets.values())}')
for key, count in buckets.items():
    print(f'{key} {count}')
" "$transcript_path" 2>/dev/null)
        printf '%s\n' "$_tst_value" > "$_tst_file"
        echo "$_tst_src_mtime" > "$_tst_stamp"
    fi

    if [ -s "$_tst_file" ]; then
        while IFS=' ' read -r _cat _cnt; do
            is_num "$_cnt" || continue
            case "$_cat" in
                TOTAL) tool_calls_total="$_cnt" ;;
                SKILLS) bucket_skills="$_cnt" ;;
                CODE) bucket_code="$_cnt" ;;
                COMMANDS) bucket_commands="$_cnt" ;;
                READ) bucket_read="$_cnt" ;;
                MCP) bucket_mcp="$_cnt" ;;
                OTHER) bucket_other="$_cnt" ;;
            esac
        done < "$_tst_file"
    fi
fi

# ---------------------------------------------------------------------------
# Line 5 — Cache Vs Tokens % | Efficiency Grade
# ---------------------------------------------------------------------------
total_for_ratio=$(( ${token_input:-0} + ${token_cc:-0} + ${token_cr:-0} ))
cache_ratio=""
if [ "$total_for_ratio" -gt 0 ]; then
    cache_ratio=$(awk "BEGIN{printf \"%.0f\", (${token_cr:-0} / $total_for_ratio) * 100}" 2>/dev/null)
fi

# Denominator is edit-capable tool calls only (the Code bucket) — counting
# read-only tools dragged exploration-heavy sessions toward F even when tool
# use was entirely appropriate. No edits yet -> the field is omitted rather
# than showing a misleading F(0).
eff_grade=""; eff_score=""
if is_num "$bucket_code" && [ "$bucket_code" -gt 0 ]; then
    lines_changed=$(( la + lr ))
    ratio=$(awk "BEGIN{printf \"%.2f\", $lines_changed / $bucket_code}" 2>/dev/null)
    eff_score=$(awk "BEGIN{s=$ratio*40; if(s>100) s=100; printf \"%.0f\", s}" 2>/dev/null)
    eff_grade=$(grade_for "$eff_score")
fi

line5=""
if is_num "$cache_ratio"; then
    if [ "$cache_ratio" -ge 75 ]; then cache_color="$GREEN"
    elif [ "$cache_ratio" -ge 40 ]; then cache_color="$ORANGE"
    else cache_color="$RED"
    fi
    line5="${WHITE}Cache Vs Tokens:${RESET} ${cache_color}${cache_ratio}%${RESET}"
fi
if [ -n "$eff_grade" ]; then
    eff_color=$(grade_color "$eff_grade")
    [ -n "$line5" ] && line5="${line5} | "
    line5="${line5}${WHITE}Efficiency Grade (A–F):${RESET} ${eff_color}${eff_grade}(${eff_score})${RESET}"
fi

# ---------------------------------------------------------------------------
# Line 6 — Tool Calls (N): the six-bucket breakdown from the shared transcript
# pass above. All six buckets always print (zeros included) — it's a fixed,
# small taxonomy, so a stable line shape beats the omit-if-zero convention
# used for the open-ended fields elsewhere.
# ---------------------------------------------------------------------------
line6=""
if is_num "$tool_calls_total" && [ "$tool_calls_total" -gt 0 ]; then
    line6="${WHITE}Tool Calls (${tool_calls_total}):${RESET}"
    line6="${line6} ${CYAN}Skills:${RESET} ${YELLOW}${bucket_skills:-0}${RESET}"
    line6="${line6} | ${CYAN}Code:${RESET} ${YELLOW}${bucket_code:-0}${RESET}"
    line6="${line6} | ${CYAN}Commands:${RESET} ${YELLOW}${bucket_commands:-0}${RESET}"
    line6="${line6} | ${CYAN}Read:${RESET} ${YELLOW}${bucket_read:-0}${RESET}"
    line6="${line6} | ${CYAN}MCP Call:${RESET} ${YELLOW}${bucket_mcp:-0}${RESET}"
    line6="${line6} | ${CYAN}Other:${RESET} ${YELLOW}${bucket_other:-0}${RESET}"
fi

# ---------------------------------------------------------------------------
# Output — only print lines that actually have content.
# Uses %s (data), never re-parses content as a format string, so literal
# '%' characters anywhere in the values can never break printf.
# ---------------------------------------------------------------------------
[ -n "$subscription_warning_line" ] && printf '%s\n' "$subscription_warning_line"
[ -n "$line1" ] && printf '%s\n' "$line1"
[ -n "$subscription_line" ] && printf '%s\n' "$subscription_line"
[ -n "$line2" ] && printf '%s\n' "$line2"
[ -n "$line3" ] && printf '%s\n' "$line3"
[ -n "$line4" ] && printf '%s\n' "$line4"
[ -n "$line5" ] && printf '%s\n' "$line5"
[ -n "$line6" ] && printf '%s\n' "$line6"

exit 0
