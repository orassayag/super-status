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
        C)   printf '%s' "$ORANGE" ;;
        D|F) printf '%s' "$RED" ;;
        *)   printf '%s' "$GREY" ;;
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
# Line 1 — Model | Repo | Branch | Worktree | Lines Changes
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
if [ "$la" -gt 0 ] || [ "$lr" -gt 0 ]; then
    [ -n "$line1" ] && line1="${line1} | "
    line1="${line1}${WHITE}Lines Changes:${RESET} ${GREEN}+${la}${RESET} ${RED}-${lr}${RESET}"
fi

# ---------------------------------------------------------------------------
# Line 2 — mode-dependent:
#   subscription mode -> Sessions: 5h / 7d usage with reset times
#   OpenRouter mode    -> live Balance bar from /api/v1/credits
#   other API-key mode -> omitted (no reliable balance source exists)
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

    five_reset_str=$(format_time_epoch "$five_reset")
    seven_reset_str=$(format_datetime_epoch "$seven_reset")

    line2="${WHITE}Sessions:${RESET} ${YELLOW}5h:${RESET} ${five_color}${five_pct}%${RESET} ${BLUE}[${five_bar}]${RESET}"
    [ -n "$five_reset_str" ] && line2="${line2} ${GREY}(Reset: ${five_reset_str})${RESET}"
    line2="${line2} | ${YELLOW}7d:${RESET} ${seven_color}${seven_pct}%${RESET} ${BLUE}[${seven_bar}]${RESET}"
    [ -n "$seven_reset_str" ] && line2="${line2} ${GREY}(Reset: ${seven_reset_str})${RESET}"

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

            line2="${WHITE}Balance:${RESET} ${or_color}\$$(printf "%.2f" "$or_remaining") / \$$(printf "%.2f" "$or_total")${RESET} ${BLUE}[${or_bar}]${RESET} ${or_color}${or_used_pct}% used${RESET}"
        fi
    fi
fi
# other API-key mode (Anthropic pay-as-you-go, z.ai, etc.): line2 stays empty,
# omitted cleanly below — no reliable balance source exists for these.

# ---------------------------------------------------------------------------
# Line 3 — Context % + bar + tokens | Cost
# ---------------------------------------------------------------------------
line3="${WHITE}Context:${RESET} ${pct_color}${pct}%${RESET} ${BLUE}[${ctx_bar}]${RESET} ${GREY}(${token_used_k}k/${token_max_k}k)${RESET}"
if is_num "$cost_usd"; then
    line3="${line3} | ${WHITE}Cost:${RESET} ${YELLOW}\$$(printf "%.2f" "$cost_usd")${RESET}"
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
session_id=$(jqr '.session_id // empty')
transcript_path=$(jqr '.transcript_path // empty')
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
        _count=$(grep -c '"type":"tool_use"' "$transcript_path" 2>/dev/null || echo 0)
        echo "${_count:-0}" > "$_ts_file"
        echo "$_src_mtime" > "$_ts_stamp"
    fi
    tool_count=$(cat "$_ts_file" 2>/dev/null || echo 0)
    tool_count=$(( ${tool_count:-0} + 0 ))
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
    line5="${line5}${WHITE}Efficiency grade (A-F):${RESET} ${eff_color}${eff_grade}(${eff_score})${RESET}"
fi
if [ -n "$tool_count" ]; then
    [ -n "$line5" ] && line5="${line5} | "
    line5="${line5}${WHITE}Tool Calls:${RESET} ${YELLOW}${tool_count}${RESET}"
fi

# ---------------------------------------------------------------------------
# Line 6 — Time (dd/MM/yyyy HH:MM) | Claude Version
# ---------------------------------------------------------------------------
now_str=$(date +"%d/%m/%Y %H:%M")
line6="${WHITE}Time:${RESET} ${GREY}${now_str}${RESET}"
if [ -n "$cc_version" ]; then
    [ -n "$line6" ] && line6="${line6} | "
    line6="${line6}${WHITE}Claude Version:${RESET} ${GREY}v${cc_version}${RESET}"
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
