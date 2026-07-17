#!/bin/bash
# super-status — combined Claude Code statusline
# Reads JSON on stdin, writes a labeled multi-line status to stdout.
# Never crashes, never prints null/undefined/NaN — missing data is simply omitted
# (that field's label, value, and separator are all dropped together).
# All full dates are rendered dd/MM/yyyy.
#
# Optional config: ~/.claude/super-status/config.json (see README). A missing
# config file means exactly the default behavior; a malformed one falls back to
# defaults and prints a one-line warning instead of failing.
# Kill switch: SUPER_STATUS_DISABLE=1 renders nothing for that session.

set -f
export LC_NUMERIC=C

# ---------------------------------------------------------------------------
# Color constants (real ESC bytes via ANSI-C quoting, not re-interpreted later)
# ---------------------------------------------------------------------------
RESET=$'\033[0m'
CYAN=$'\033[36m'
GREEN=$'\033[32m'
GREY=$'\033[90m'
WHITE=$'\033[37m'
RED=$'\033[31m'
BOLD_RED=$'\033[1;31m'
ORANGE=$'\033[38;5;208m'
YELLOW=$'\033[33m'

# ---------------------------------------------------------------------------
# Config defaults — a missing/empty config.json yields exactly these, which
# reproduce the pre-config behavior of this script. New-in-2.0 elements
# (activity/agents/todos lines, git dirty/ahead-behind/file-stats markers)
# therefore default OFF; enable them per key or via "preset": "full".
# ---------------------------------------------------------------------------
cfg_language="en"
cfg_layout="expanded"
cfg_bar_width=10
cfg_bar_filled="#"
cfg_bar_empty="-"
cfg_path_levels=1
cfg_max_width=0
cfg_context_value="both"
cfg_lines=""

cfg_show_model=1
cfg_show_repo=1
cfg_show_branch=1
cfg_show_worktree=1
cfg_show_lines_changed=1
cfg_show_version=1
cfg_show_git_dirty=0
cfg_show_git_ahead_behind=0
cfg_show_git_file_stats=0
cfg_show_provider=1
cfg_show_subscription=1
cfg_show_sessions=1
cfg_show_balance=1
cfg_show_context=1
cfg_show_cost=1
cfg_show_total_tokens=1
cfg_show_loc=1
cfg_show_session_time=1
cfg_show_thinking_time=1
cfg_show_cache_ratio=1
cfg_show_efficiency=1
cfg_show_tool_calls=1
cfg_show_activity=0
cfg_show_agents=0
cfg_show_todos=0
cfg_show_orchestrator=0

cfg_push_warning=3
cfg_push_critical=10

cfg_ctx_warn=70
cfg_ctx_crit=90
cfg_5h_warn=70
cfg_5h_crit=90
cfg_7d_warn=50
cfg_7d_crit=75

cfg_color_label=""
cfg_color_model=""
cfg_color_repo=""
cfg_color_branch=""
cfg_color_muted=""
cfg_color_accent=""
cfg_color_bar_filled=""
cfg_color_bar_empty=""

# Layout presets: lines separated by "|", segments within a line by ",".
# A custom "lines" array in config.json overrides either preset, which is how
# element reordering and merging elements onto shared lines is expressed.
LAYOUT_EXPANDED="model,repo,branch,worktree,lines_changed,version|subscription,sessions,balance|context,cache_ratio,cost,total_tokens|loc,session_time,thinking_time,efficiency,tool_calls|activity|agents|todos|orchestrator"
LAYOUT_COMPACT="model,repo,branch,worktree,context|subscription,sessions,balance,cost|activity,agents,todos,orchestrator"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
is_num() { [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; }

to_bool() {
    case "$1" in
        true|1) echo 1 ;;
        false|0) echo 0 ;;
        *) return 1 ;;
    esac
}

# Named ANSI colors, 256-color numbers, and #RRGGBB hex -> escape sequence.
# Prints nothing (and fails) for anything unrecognized, so an invalid config
# value keeps the built-in default instead of emitting garbage bytes.
resolve_color() {
    local name="$1"
    case "$name" in
        black)   printf '\033[30m' ;;
        red)     printf '\033[31m' ;;
        green)   printf '\033[32m' ;;
        yellow)  printf '\033[33m' ;;
        blue)    printf '\033[34m' ;;
        magenta) printf '\033[35m' ;;
        cyan)    printf '\033[36m' ;;
        white)   printf '\033[37m' ;;
        grey|gray) printf '\033[90m' ;;
        bright-red)     printf '\033[91m' ;;
        bright-green)   printf '\033[92m' ;;
        bright-yellow)  printf '\033[93m' ;;
        bright-blue)    printf '\033[94m' ;;
        bright-magenta) printf '\033[95m' ;;
        bright-cyan)    printf '\033[96m' ;;
        bright-white)   printf '\033[97m' ;;
        orange) printf '\033[38;5;208m' ;;
        *)
            if [[ "$name" =~ ^([0-9]{1,3})$ ]] && [ "$name" -le 255 ]; then
                printf '\033[38;5;%dm' "$name"
            elif [[ "$name" =~ ^#[0-9a-fA-F]{6}$ ]]; then
                printf '\033[38;2;%d;%d;%dm' \
                    "$(( 16#${name:1:2} ))" "$(( 16#${name:3:2} ))" "$(( 16#${name:5:2} ))"
            else
                return 1
            fi
            ;;
    esac
}

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

# Elapsed seconds -> "2m15s" / "1h5m" / "42s" — used for in-flight agent timers.
fmt_elapsed_s() {
    local s="$1"
    is_num "$s" || { echo ""; return; }
    s=${s%.*}
    [ "$s" -lt 0 ] && s=0
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

# $1 pct, $2 warning threshold, $3 critical threshold
usage_color() {
    local u="$1" warn="$2" crit="$3"
    is_num "$u" || { printf '%s' "$GREY"; return; }
    u=${u%.*}
    if [ "$u" -ge 100 ] || [ "$u" -ge "$crit" ]; then printf '%s' "$RED"
    elif [ "$u" -ge "$warn" ]; then printf '%s' "$ORANGE"
    else printf '%s' "$GREEN"
    fi
}

# dd/MM/yyyy only — used for the subscription cycle renewal date and the
# weekly reset date.
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

# Uncolored glyph bar. Glyphs are configurable (e.g. █/░); built by loop, not
# `tr`, because tr is byte-oriented and mangles multi-byte glyphs.
make_bar() {
    local pct="$1" width="${2:-20}"
    is_num "$pct" || pct=0
    pct=${pct%.*}
    [ "$pct" -lt 0 ] && pct=0
    [ "$pct" -gt 100 ] && pct=100
    local filled=$(( pct * width / 100 ))
    [ "$filled" -gt "$width" ] && filled=$width
    local empty=$(( width - filled )) out="" i
    for (( i = 0; i < filled; i++ )); do out+="$cfg_bar_filled"; done
    for (( i = 0; i < empty; i++ )); do out+="$cfg_bar_empty"; done
    printf '%s' "$out"
}

# Colored bar unit (no brackets — every bar on every line is the same
# cfg_bar_width cells, so stacked bars align in a column): $1 pct, $2
# outer/usage color. Per-part color overrides only add escape sequences when
# actually configured.
render_bar() {
    local pct="$1" outer="$2"
    is_num "$pct" || pct=0
    pct=${pct%.*}
    [ "$pct" -lt 0 ] && pct=0
    local p="$pct"
    [ "$p" -gt 100 ] && p=100
    local nf=$(( p * cfg_bar_width / 100 ))
    [ "$nf" -gt "$cfg_bar_width" ] && nf=$cfg_bar_width
    local ne=$(( cfg_bar_width - nf )) fstr="" estr="" i
    for (( i = 0; i < nf; i++ )); do fstr+="$cfg_bar_filled"; done
    for (( i = 0; i < ne; i++ )); do estr+="$cfg_bar_empty"; done
    if [ -z "$C_BAR_FILLED" ] && [ -z "$C_BAR_EMPTY" ]; then
        printf '%s' "${outer}${fstr}${estr}${RESET}"
    else
        printf '%s' "${C_BAR_FILLED:-$outer}${fstr}${RESET}${C_BAR_EMPTY:-$outer}${estr}${RESET}"
    fi
}

# Muted-gray wrapper — the one place the "informational, not actionable"
# color is applied, so those fields can never drift onto warning colors.
muted() {
    printf '%s%s%s' "$C_MUTED" "$1" "$RESET"
}

# Last $2 components of path $1, joined by "/" — pathLevels support.
path_tail() {
    local p="${1%/}" n="$2" out="" i
    local parts=() IFS='/'
    read -ra parts <<< "$p"
    local cnt=${#parts[@]}
    local start=$(( cnt - n ))
    [ "$start" -lt 0 ] && start=0
    for (( i = start; i < cnt; i++ )); do
        [ -n "${parts[i]}" ] || continue
        out+="${out:+/}${parts[i]}"
    done
    printf '%s' "$out"
}

file_mtime() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

trim_ws() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# UTC ISO-8601 (e.g. "2026-07-17T10:00:00Z") -> epoch seconds. Same BSD/GNU
# dual-command fallback as parse_subscription_date above; prints nothing on
# unparseable input rather than failing the caller.
parse_iso_epoch() {
    local _t="$1"
    date -d "$_t" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$_t" +%s 2>/dev/null
}

# ---------------------------------------------------------------------------
# Everything below is the render flow; sourcing the script (tests) stops here
# so the pure functions above are unit-testable without stdin or side effects.
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    return 0
fi

# Kill switch — stdin is still drained so the writer never sees a broken pipe.
if [ "${SUPER_STATUS_DISABLE:-0}" = "1" ]; then
    cat > /dev/null
    exit 0
fi

input=$(cat)

# ---------------------------------------------------------------------------
# Private per-user cache root (XDG). /tmp is world-readable and its predictable
# paths are pre-creatable by other local users, so caches live here instead.
# ---------------------------------------------------------------------------
CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/super-status"
if [ ! -d "$CACHE_ROOT" ]; then
    mkdir -p "$CACHE_ROOT" 2>/dev/null
    chmod 700 "$CACHE_ROOT" 2>/dev/null
fi

# ---------------------------------------------------------------------------
# Config load — one jq call over config.json emits key<TAB>value rows for a
# fixed key set; unknown keys are ignored, absent keys keep their defaults.
# "preset" is emitted first so explicit per-key values always override it.
# ---------------------------------------------------------------------------
CONFIG_FILE="${SUPER_STATUS_CONFIG:-$HOME/.claude/super-status/config.json}"
config_warning_line=""

apply_preset() {
    local _v
    case "$1" in
        full)
            for _v in git_dirty git_ahead_behind git_file_stats activity agents todos orchestrator; do
                printf -v "cfg_show_${_v}" '%s' 1
            done
            ;;
        essential)
            for _v in lines_changed version git_file_stats total_tokens loc session_time \
                      thinking_time cache_ratio efficiency tool_calls activity; do
                printf -v "cfg_show_${_v}" '%s' 0
            done
            for _v in git_dirty git_ahead_behind agents todos orchestrator; do
                printf -v "cfg_show_${_v}" '%s' 1
            done
            ;;
        minimal)
            for _v in repo worktree lines_changed version git_dirty git_ahead_behind \
                      git_file_stats provider subscription cost total_tokens loc \
                      session_time thinking_time cache_ratio efficiency tool_calls \
                      activity agents todos orchestrator; do
                printf -v "cfg_show_${_v}" '%s' 0
            done
            cfg_layout="compact"
            ;;
    esac
}

if [ -f "$CONFIG_FILE" ]; then
    if ! _cfg_out=$(jq -r '
        def s(v): if v == null then "" else (v | tostring) end;
        (
          [
            ["preset", s(.preset)],
            ["language", s(.language)],
            ["layout", s(.layout)],
            ["bar_width", s(.bar_width)],
            ["bar_filled", s(.bar_filled)],
            ["bar_empty", s(.bar_empty)],
            ["path_levels", s(.path_levels)],
            ["max_width", s(.max_width)],
            ["context_value", s(.context_value)],
            ["lines", (try (.lines | map(join(",")) | join("|")) catch "")],
            ["push_warning_threshold", s(.git.push_warning_threshold)],
            ["push_critical_threshold", s(.git.push_critical_threshold)]
          ]
          + ((.display // {}) | to_entries | map(["display_" + .key, s(.value)]))
          + ((.colors // {}) | to_entries | map(["color_" + .key, s(.value)]))
          + ((.thresholds // {}) | to_entries | map(["threshold_" + .key, s(.value)]))
        ) | .[] | @tsv' "$CONFIG_FILE" 2>/dev/null); then
        config_warning_line="${BOLD_RED}SUPER-STATUS CONFIG IS INVALID JSON - USING DEFAULTS: ${CONFIG_FILE}${RESET}"
    else
        while IFS=$'\t' read -r _k _v; do
            [ -n "$_k" ] || continue
            case "$_k" in
                preset) [ -n "$_v" ] && apply_preset "$_v" ;;
                language) [ -n "$_v" ] && cfg_language="$_v" ;;
                layout) case "$_v" in expanded|compact) cfg_layout="$_v" ;; esac ;;
                bar_width) is_num "$_v" && [ "${_v%.*}" -ge 5 ] && [ "${_v%.*}" -le 60 ] && cfg_bar_width="${_v%.*}" ;;
                bar_filled) [ -n "$_v" ] && cfg_bar_filled="${_v:0:1}" ;;
                bar_empty) [ -n "$_v" ] && cfg_bar_empty="${_v:0:1}" ;;
                path_levels) is_num "$_v" && [ "${_v%.*}" -ge 1 ] && [ "${_v%.*}" -le 5 ] && cfg_path_levels="${_v%.*}" ;;
                max_width) is_num "$_v" && [ "${_v%.*}" -ge 0 ] && cfg_max_width="${_v%.*}" ;;
                context_value) case "$_v" in percent|tokens|remaining|both) cfg_context_value="$_v" ;; esac ;;
                lines) [ -n "$_v" ] && cfg_lines="$_v" ;;
                push_warning_threshold) is_num "$_v" && cfg_push_warning="${_v%.*}" ;;
                push_critical_threshold) is_num "$_v" && cfg_push_critical="${_v%.*}" ;;
                display_*)
                    _b=$(to_bool "$_v") || continue
                    case "${_k#display_}" in
                        model|repo|branch|worktree|lines_changed|version|git_dirty|git_ahead_behind|git_file_stats|provider|subscription|sessions|balance|context|cost|total_tokens|loc|session_time|thinking_time|cache_ratio|efficiency|tool_calls|activity|agents|todos|orchestrator)
                            printf -v "cfg_show_${_k#display_}" '%s' "$_b" ;;
                    esac
                    ;;
                color_*)
                    case "${_k#color_}" in
                        label|model|repo|branch|muted|accent|bar_filled|bar_empty)
                            printf -v "cfg_color_${_k#color_}" '%s' "$_v" ;;
                    esac
                    ;;
                threshold_*)
                    is_num "$_v" || continue
                    case "${_k#threshold_}" in
                        context_warning) cfg_ctx_warn="${_v%.*}" ;;
                        context_critical) cfg_ctx_crit="${_v%.*}" ;;
                        five_hour_warning) cfg_5h_warn="${_v%.*}" ;;
                        five_hour_critical) cfg_5h_crit="${_v%.*}" ;;
                        seven_day_warning) cfg_7d_warn="${_v%.*}" ;;
                        seven_day_critical) cfg_7d_crit="${_v%.*}" ;;
                    esac
                    ;;
            esac
        done <<< "$_cfg_out"
    fi
fi

# Element colors: built-in defaults, overridable per element from config.
# The model accent is the same green as "healthy" bar values on purpose —
# identity/accent and healthy read as one color family, per the redesign.
C_LABEL="$WHITE"; C_MODEL="$GREEN"; C_REPO="$WHITE"; C_BRANCH="$WHITE"
C_MUTED="$GREY"; C_ACCENT="$YELLOW"; C_BAR_FILLED=""; C_BAR_EMPTY=""
_c=$(resolve_color "$cfg_color_label") && C_LABEL="$_c"
_c=$(resolve_color "$cfg_color_model") && C_MODEL="$_c"
_c=$(resolve_color "$cfg_color_repo") && C_REPO="$_c"
_c=$(resolve_color "$cfg_color_branch") && C_BRANCH="$_c"
_c=$(resolve_color "$cfg_color_muted") && C_MUTED="$_c"
_c=$(resolve_color "$cfg_color_accent") && C_ACCENT="$_c"
_c=$(resolve_color "$cfg_color_bar_filled") && C_BAR_FILLED="$_c"
_c=$(resolve_color "$cfg_color_bar_empty") && C_BAR_EMPTY="$_c"

# ---------------------------------------------------------------------------
# Labels — every rendered string lives here, keyed by the "language" config
# value. Only "en" ships today; adding a language means adding one case branch.
# ---------------------------------------------------------------------------
case "$cfg_language" in
    en|*)
        L_MODEL="◆"
        L_SUBSCRIPTION="Sub"
        L_FIVE_HOUR="5h"
        L_BALANCE="Bal"
        L_CONTEXT="Ctx"
        L_COST="Cost"
        L_COST_EST="Cost est."
        L_TOTAL_TOKENS="Tok"
        L_LOC="LOC"
        L_SESSION_TIME="Session"
        L_THINKING="Thinking"
        L_CACHE_RATIO="Cache"
        L_EFFICIENCY="Eff"
        L_TOOL_CALLS="Calls"
        L_BUCKET_SKILLS="Skill"
        L_BUCKET_CODE="Code"
        L_BUCKET_COMMANDS="Bash"
        L_BUCKET_READ="Read"
        L_BUCKET_MCP="MCP"
        L_BUCKET_OTHER="Other"
        L_ACTIVITY="Activity:"
        L_AGENTS="Agents:"
        L_TODO="Todo:"
        L_ORCA="Orca:"
        L_MASTER="Master:"
        L_RESET="Reset"
        L_LEFT="left"
        L_SUB_MISSING='SUBSCRIPTION START DATE IS MISSING - ADD IT TO THE CLAUDE.MD: "subscription_start_date": "dd/MM/yyyy"'
        L_SUB_INVALID='SUBSCRIPTION START DATE IS INVALID - ADD IT TO THE CLAUDE.MD: "subscription_start_date": "dd/MM/yyyy"'
        ;;
esac

# ---------------------------------------------------------------------------
# Single-pass stdin parse — one jq call emits every needed field as
# key<TAB>value (replacing ~25 per-field jq spawns). @tsv escapes embedded
# tabs/newlines so the read loop can never be desynced by data.
# ---------------------------------------------------------------------------
model=""; project_dir=""; cwd=""; current_dir=""; worktree=""
session_id=""; transcript_path=""; cc_version=""
sv_used_pct=""; sv_remaining_pct=""; sv_window_size=""
sv_cur_in=""; sv_cur_cc=""; sv_cur_cr=""
api_ms=""; dur_ms=""; cost_usd=""; lines_added=""; lines_removed=""
five_util_probe=""; five_reset=""; seven_util_probe=""; seven_reset=""

while IFS=$'\t' read -r _k _v; do
    case "$_k" in
        model) model="$_v" ;;
        project_dir) project_dir="$_v" ;;
        cwd) cwd="$_v" ;;
        current_dir) current_dir="$_v" ;;
        worktree) worktree="$_v" ;;
        session_id) session_id="$_v" ;;
        transcript_path) transcript_path="$_v" ;;
        version) cc_version="$_v" ;;
        used_pct) sv_used_pct="$_v" ;;
        remaining_pct) sv_remaining_pct="$_v" ;;
        window_size) sv_window_size="$_v" ;;
        cur_in) sv_cur_in="$_v" ;;
        cur_cc) sv_cur_cc="$_v" ;;
        cur_cr) sv_cur_cr="$_v" ;;
        api_ms) api_ms="$_v" ;;
        dur_ms) dur_ms="$_v" ;;
        cost_usd) cost_usd="$_v" ;;
        cost_la) lines_added="$_v" ;;
        cost_lr) lines_removed="$_v" ;;
        five_pct) five_util_probe="$_v" ;;
        five_reset) five_reset="$_v" ;;
        seven_pct) seven_util_probe="$_v" ;;
        seven_reset) seven_reset="$_v" ;;
    esac
done <<< "$(jq -r '
    def s(v): if v == null then "" else (v | tostring) end;
    [
      ["model", s(.model.display_name)],
      ["project_dir", s(.workspace.project_dir)],
      ["cwd", s(.cwd)],
      ["current_dir", s(.workspace.current_dir)],
      ["worktree", s(.workspace.git_worktree)],
      ["session_id", s(.session_id)],
      ["transcript_path", s(.transcript_path)],
      ["version", s(.version)],
      ["used_pct", s(.context_window.used_percentage)],
      ["remaining_pct", s(.context_window.remaining_percentage)],
      ["window_size", s(.context_window.context_window_size)],
      ["cur_in", s(.context_window.current_usage.input_tokens)],
      ["cur_cc", s(.context_window.current_usage.cache_creation_input_tokens)],
      ["cur_cr", s(.context_window.current_usage.cache_read_input_tokens)],
      ["api_ms", s(.cost.total_api_duration_ms)],
      ["dur_ms", s(.cost.total_duration_ms)],
      ["cost_usd", s(.cost.total_cost_usd)],
      ["cost_la", s(.cost.total_lines_added)],
      ["cost_lr", s(.cost.total_lines_removed)],
      ["five_pct", s(.rate_limits.five_hour.used_percentage)],
      ["five_reset", s(.rate_limits.five_hour.resets_at)],
      ["seven_pct", s(.rate_limits.seven_day.used_percentage)],
      ["seven_reset", s(.rate_limits.seven_day.resets_at)]
    ] | .[] | @tsv' <<< "$input" 2>/dev/null)"

[ "$worktree" = "null" ] && worktree=""
[ -z "$cwd" ] && cwd="$current_dir"

git_root=$(git -C "${cwd:-$project_dir}" rev-parse --show-toplevel 2>/dev/null)
[ -z "$git_root" ] && git_root="${cwd:-$project_dir}"
git_branch=""
[ -n "$git_root" ] && [ -d "$git_root" ] && \
    git_branch=$(GIT_OPTIONAL_LOCKS=0 git -C "$git_root" rev-parse --abbrev-ref HEAD 2>/dev/null)

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

IS_SUBSCRIPTION=0
is_num "$five_util_probe" && is_num "$seven_util_probe" && IS_SUBSCRIPTION=1

# Provider badge on the model segment — first-party Anthropic shows nothing;
# any other backend is named explicitly so the backend mode is visible at a glance.
provider_badge=""
if [ "$cfg_show_provider" = "1" ]; then
    if [ "$IS_OPENROUTER" -eq 1 ]; then
        provider_badge="OpenRouter"
    elif [ -n "$ANTHROPIC_BASE_URL" ]; then
        case "$ANTHROPIC_BASE_URL" in
            *api.anthropic.com*) ;;
            *z.ai*|*bigmodel*) provider_badge="z.ai" ;;
            *)
                _pb="${ANTHROPIC_BASE_URL#*://}"
                provider_badge="${_pb%%/*}"
                ;;
        esac
    fi
fi

# ---------------------------------------------------------------------------
# LOC count (60s cache per git root)
# ---------------------------------------------------------------------------
loc_value=""
if [ "$cfg_show_loc" = "1" ] && [ -n "$git_root" ] && [ -d "$git_root" ] && command -v tokei >/dev/null 2>&1; then
    _loc_dir="$CACHE_ROOT/loc-cache"
    mkdir -p "$_loc_dir"
    _key=$(echo "$git_root" | tr '/' '_')
    _loc_file="$_loc_dir/${_key}.txt"
    _loc_stamp="$_loc_dir/${_key}.stamp"
    _do_count=1
    if [ -f "$_loc_stamp" ]; then
        _age=$(( $(date +%s) - $(file_mtime "$_loc_stamp") ))
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
# Git status enrichment (10s cache per git root): dirty marker, ahead/behind
# vs. upstream, and modified/staged/untracked file counts.
# ---------------------------------------------------------------------------
git_dirty=""; git_ahead=""; git_behind=""
git_staged=""; git_modified=""; git_untracked=""
if [ -n "$git_branch" ] && { [ "$cfg_show_git_dirty" = "1" ] || [ "$cfg_show_git_ahead_behind" = "1" ] || [ "$cfg_show_git_file_stats" = "1" ]; }; then
    _gs_dir="$CACHE_ROOT/gitstatus-cache"
    mkdir -p "$_gs_dir"
    _gs_key=$(echo "$git_root" | tr '/' '_')
    _gs_file="$_gs_dir/${_gs_key}.txt"
    _gs_stamp="$_gs_dir/${_gs_key}.stamp"
    _gs_do=1
    if [ -f "$_gs_stamp" ]; then
        _gs_age=$(( $(date +%s) - $(file_mtime "$_gs_stamp") ))
        [ "$_gs_age" -lt 10 ] && _gs_do=0
    fi
    if [ "$_gs_do" -eq 1 ]; then
        _d=0; _st=0; _mo=0; _un=0; _ah=""; _bh=""
        if [ "$cfg_show_git_file_stats" = "1" ]; then
            while IFS= read -r _pline; do
                [ -n "$_pline" ] || continue
                _d=1
                case "${_pline:0:2}" in
                    '??') _un=$(( _un + 1 )) ;;
                    *)
                        case "${_pline:0:1}" in [MADRC]) _st=$(( _st + 1 )) ;; esac
                        case "${_pline:1:1}" in [MD]) _mo=$(( _mo + 1 )) ;; esac
                        ;;
                esac
            done < <(GIT_OPTIONAL_LOCKS=0 git -C "$git_root" status --porcelain 2>/dev/null)
        else
            # First line only — a dirty/clean answer doesn't need the full listing.
            _first=$(GIT_OPTIONAL_LOCKS=0 git -C "$git_root" status --porcelain 2>/dev/null | head -n 1)
            [ -n "$_first" ] && _d=1
        fi
        if [ "$cfg_show_git_ahead_behind" = "1" ]; then
            read -r _bh _ah <<< "$(GIT_OPTIONAL_LOCKS=0 git -C "$git_root" rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null)"
        fi
        echo "$_d ${_ah:--} ${_bh:--} $_st $_mo $_un" > "$_gs_file"
        touch "$_gs_stamp"
    fi
    read -r git_dirty git_ahead git_behind git_staged git_modified git_untracked < "$_gs_file" 2>/dev/null
    [ "$git_ahead" = "-" ] && git_ahead=""
    [ "$git_behind" = "-" ] && git_behind=""
fi

# ---------------------------------------------------------------------------
# Orca / Master live run state — reads the same on-disk files orca's
# SKILL-ledger.sh and master's stage-plan.md already treat as their source of
# truth (.claude/status.md, docs/status/stage-plan.md). Wave agents run as
# separate cmux-worktree processes with their own transcript, invisible to
# this session's stdin JSON — this is the only signal this script has of
# them. Read-only; never writes either file. Checked unconditionally (no
# existence gate) since both are small local files — cheaper than a stat
# round-trip to decide whether to look. Orca is preferred if both are present
# (a stale file left over from a previous run of the other kind).
# ---------------------------------------------------------------------------
orca_total=0; orca_merged=0; orca_conflict=0; orca_blocked=0; orca_inprogress=0; orca_done=0
master_total=0; master_committed=0
master_open_num=""; master_open_status=""; master_open_title=""; master_open_spawned=""
if [ "$cfg_show_orchestrator" = "1" ] && [ -n "$git_root" ]; then
    _orca_status_file="$git_root/.claude/status.md"
    if [ -f "$_orca_status_file" ]; then
        while IFS='|' read -r _ _os_name _ _ _ _os_status _ _; do
            _os_name=$(trim_ws "$_os_name")
            _os_status=$(trim_ws "$_os_status")
            [ -z "$_os_name" ] && continue
            [ "$_os_name" = "Agent" ] && continue
            echo "$_os_name" | grep -qE '^-+$' && continue
            orca_total=$(( orca_total + 1 ))
            case "$_os_status" in
                "REBASED & MERGED") orca_merged=$(( orca_merged + 1 )) ;;
                "CONFLICT — NEEDS YOU") orca_conflict=$(( orca_conflict + 1 )) ;;
                BLOCKED) orca_blocked=$(( orca_blocked + 1 )) ;;
                "IN PROGRESS") orca_inprogress=$(( orca_inprogress + 1 )) ;;
                DONE) orca_done=$(( orca_done + 1 )) ;;
            esac
        done < <(grep '^|' "$_orca_status_file" 2>/dev/null)
    fi

    _master_plan_file="$git_root/docs/status/stage-plan.md"
    if [ -f "$_master_plan_file" ]; then
        while IFS= read -r _ms_line; do
            case "$_ms_line" in
                "- Stage "*": "*" — "*) ;;
                *) continue ;;
            esac
            _ms_rest1="${_ms_line#- Stage }"
            _ms_num="${_ms_rest1%%:*}"
            is_num "$_ms_num" || continue
            _ms_rest2="${_ms_rest1#*: }"
            _ms_status=$(trim_ws "${_ms_rest2%% — *}")
            _ms_title="${_ms_rest2#* — }"
            master_total=$(( master_total + 1 ))
            if [ "$_ms_status" = "COMMITTED" ]; then
                master_committed=$(( master_committed + 1 ))
            elif [ -z "$master_open_num" ]; then
                master_open_num="$_ms_num"
                master_open_status="$_ms_status"
                if [[ "$_ms_title" == *"spawned="* ]]; then
                    _ms_sp="${_ms_title#*spawned=}"
                    master_open_spawned=$(trim_ws "${_ms_sp%%]*}")
                fi
                if [[ "$_ms_title" == *"["* ]]; then
                    master_open_title=$(trim_ws "${_ms_title%%\[*}")
                else
                    master_open_title=$(trim_ws "$_ms_title")
                fi
            fi
        done < "$_master_plan_file"
    fi
fi

# ---------------------------------------------------------------------------
# Context window % + bar + tokens
# ---------------------------------------------------------------------------
pct="$sv_used_pct"
window_size="$sv_window_size"
is_num "$window_size" || window_size=200000
token_input="${sv_cur_in:-0}"; is_num "$token_input" || token_input=0
token_cc="${sv_cur_cc:-0}"; is_num "$token_cc" || token_cc=0
token_cr="${sv_cur_cr:-0}"; is_num "$token_cr" || token_cr=0
token_total=$(( ${token_input%.*} + ${token_cc%.*} + ${token_cr%.*} ))
if ! is_num "$pct"; then
    pct=$(( window_size > 0 ? token_total * 100 / window_size : 0 ))
fi
pct=${pct%.*}
is_num "$pct" || pct=0
[ "$pct" -lt 0 ] && pct=0
[ "$pct" -gt 100 ] && pct=100
pct_color=$(usage_color "$pct" "$cfg_ctx_warn" "$cfg_ctx_crit")

token_used_k=$(( token_total / 1000 ))
token_max_k=$(( window_size / 1000 ))

# Remaining tokens before auto-compact: Claude Code's own remaining_percentage
# is preferred when present (it accounts for the auto-compact threshold, so
# the raw window size isn't assumed to be the usable budget); otherwise it
# falls back to window minus used.
remaining_tokens=""
if is_num "$sv_remaining_pct"; then
    remaining_tokens=$(awk "BEGIN{printf \"%d\", $window_size * $sv_remaining_pct / 100}")
else
    remaining_tokens=$(( window_size - token_total ))
fi
[ "$remaining_tokens" -lt 0 ] && remaining_tokens=0
remaining_k=$(( remaining_tokens / 1000 ))

# ---------------------------------------------------------------------------
# Shared transcript pass — ONE python3 run (cached by transcript mtime) feeds
# five consumers: cumulative token totals, the six tool-call buckets, the
# live activity groups, in-flight subagents, and the latest todo state.
#
# Token totals: neither total_input_tokens nor total_output_tokens is trusted
# straight from Claude Code's own JSON. total_output_tokens reflects only the
# last exchange's output, not a running total, and total_input_tokens stays
# null/absent until the first real API call — so both are derived by summing
# every assistant message's usage fields out of the transcript JSONL.
#
# Buckets: every tool_use block maps into exactly one of six semantic buckets
# (Skills / Code / Commands / Read / MCP Call / Other) so the bucket sum always
# equals the printed total by construction. The Code bucket doubles as the
# Efficiency Grade denominator.
#
# In-flight detection: a tool_use whose id has no matching tool_result yet is
# "running" — that's what marks the activity spinner and live agents.
# ---------------------------------------------------------------------------
session_total_input=""; session_total_output=""
tool_calls_total=""
bucket_skills=""; bucket_code=""; bucket_commands=""
bucket_read=""; bucket_mcp=""; bucket_other=""
activity_value=""
agents_value=""
todo_value=""

_need_transcript=0
for _flag in "$cfg_show_total_tokens" "$cfg_show_tool_calls" "$cfg_show_efficiency" \
             "$cfg_show_activity" "$cfg_show_agents" "$cfg_show_todos"; do
    [ "$_flag" = "1" ] && _need_transcript=1
done

if [ "$_need_transcript" -eq 1 ] && [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    _tr_dir="$CACHE_ROOT/transcript-cache"
    mkdir -p "$_tr_dir"
    _tr_key="${session_id:-$(echo "$transcript_path" | tr '/' '_')}"
    _tr_file="$_tr_dir/${_tr_key}.txt"
    _tr_stamp="$_tr_dir/${_tr_key}.mtime"
    _tr_src_mtime=$(file_mtime "$transcript_path")
    _tr_cached_mtime=$(cat "$_tr_stamp" 2>/dev/null || echo -1)
    if [ "$_tr_src_mtime" != "$_tr_cached_mtime" ]; then
        _tr_value=$(python3 - "$transcript_path" 2>/dev/null <<'PYEOF'
import json
import os
import sys
from datetime import datetime

path = sys.argv[1]
total_in = 0
total_out = 0
buckets = {'SKILLS': 0, 'CODE': 0, 'COMMANDS': 0, 'READ': 0, 'MCP': 0, 'OTHER': 0}
code_tools = {'edit', 'write', 'multiedit', 'notebookedit'}
read_tools = {'read', 'glob', 'grep', 'ls'}
agent_tools = {'task', 'agent'}

tools = []
tools_by_id = {}
latest_todos = None


def clean(text, limit):
    if not isinstance(text, str):
        return ''
    return text.replace('\t', ' ').replace('\n', ' ').strip()[:limit]


def to_epoch(timestamp):
    if not isinstance(timestamp, str):
        return ''
    try:
        return str(int(datetime.fromisoformat(timestamp.replace('Z', '+00:00')).timestamp()))
    except Exception:
        return ''


def target_for(name, tool_input):
    if not isinstance(tool_input, dict):
        return ''
    low = name.lower()
    file_path = tool_input.get('file_path') or tool_input.get('path') or tool_input.get('notebook_path')
    if isinstance(file_path, str) and file_path:
        return os.path.basename(file_path)
    if low == 'bash':
        command = tool_input.get('command')
        if isinstance(command, str) and command.strip():
            return command.strip().split()[0].rsplit('/', 1)[-1]
    if low in ('grep', 'glob'):
        return clean(tool_input.get('pattern'), 20)
    if low == 'skill':
        return clean(tool_input.get('skill'), 30)
    if low == 'webfetch' or low == 'websearch':
        return clean(tool_input.get('url') or tool_input.get('query'), 30)
    return ''


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
            role = msg.get('role')
            content = msg.get('content')
            if role == 'assistant':
                usage = msg.get('usage') or {}
                for key in ('input_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens'):
                    value = usage.get(key)
                    if isinstance(value, (int, float)):
                        total_in += value
                out = usage.get('output_tokens')
                if isinstance(out, (int, float)):
                    total_out += out
            if not isinstance(content, list):
                continue
            for block in content:
                if not isinstance(block, dict):
                    continue
                btype = block.get('type')
                if btype == 'tool_use' and role == 'assistant':
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
                    tool_input = block.get('input')
                    entry = {
                        'id': block.get('id'),
                        'name': name,
                        'low': low,
                        'done': False,
                        'epoch': to_epoch(obj.get('timestamp')),
                        'target': clean(target_for(name, tool_input), 30),
                    }
                    if low in agent_tools and isinstance(tool_input, dict):
                        entry['agent'] = True
                        entry['desc'] = clean(tool_input.get('description') or tool_input.get('prompt'), 50)
                        entry['atype'] = clean(tool_input.get('subagent_type'), 30) or 'agent'
                        entry['amodel'] = clean(tool_input.get('model'), 20)
                    if low == 'todowrite' and isinstance(tool_input, dict):
                        todos = tool_input.get('todos')
                        if isinstance(todos, list):
                            latest_todos = todos
                    tools.append(entry)
                    if entry['id']:
                        tools_by_id[entry['id']] = entry
                elif btype == 'tool_result':
                    tool_id = block.get('tool_use_id')
                    if tool_id in tools_by_id:
                        tools_by_id[tool_id]['done'] = True
except Exception:
    pass

print(f'TOKENS\t{int(total_in)}\t{int(total_out)}')
print(f'BUCKET\tTOTAL\t{sum(buckets.values())}')
for key, count in buckets.items():
    print(f'BUCKET\t{key}\t{count}')

# Activity groups: newest first, consecutive completed calls of the same tool
# collapsed into one "×N" group. Agents and TodoWrite have their own lines.
groups = []
for entry in reversed(tools):
    if entry.get('agent') or entry['low'] == 'todowrite':
        continue
    status = 'done' if entry['done'] else 'run'
    if groups and status == 'done' and groups[-1]['status'] == 'done' and groups[-1]['name'] == entry['name']:
        groups[-1]['count'] += 1
        continue
    if len(groups) >= 5:
        break
    groups.append({'name': entry['name'], 'status': status, 'count': 1, 'target': entry['target']})
for group in groups:
    target = group['target'] if group['count'] == 1 else ''
    print(f"ACT\t{group['status']}\t{group['count']}\t{group['name']}\t{target}")

for entry in tools:
    if entry.get('agent') and not entry['done']:
        print(f"AGENT\t{entry['epoch']}\t{entry['atype']}\t{entry['amodel']}\t{entry['desc']}")

if latest_todos:
    total = len(latest_todos)
    completed = sum(1 for t in latest_todos if isinstance(t, dict) and t.get('status') == 'completed')
    current = next((t for t in latest_todos if isinstance(t, dict) and t.get('status') == 'in_progress'), None)
    if current is None:
        current = next((t for t in latest_todos if isinstance(t, dict) and t.get('status') == 'pending'), None)
    text = ''
    if isinstance(current, dict):
        text = clean(current.get('activeForm') or current.get('content'), 60)
    print(f'TODO\t{completed}\t{total}\t{text}')
PYEOF
)
        printf '%s\n' "$_tr_value" > "$_tr_file"
        echo "$_tr_src_mtime" > "$_tr_stamp"
    fi

    if [ -s "$_tr_file" ]; then
        _now_epoch=$(date +%s)
        while IFS=$'\t' read -r _tag _a _b _c _d; do
            case "$_tag" in
                TOKENS)
                    session_total_input="$_a"; session_total_output="$_b" ;;
                BUCKET)
                    is_num "$_b" || continue
                    case "$_a" in
                        TOTAL) tool_calls_total="$_b" ;;
                        SKILLS) bucket_skills="$_b" ;;
                        CODE) bucket_code="$_b" ;;
                        COMMANDS) bucket_commands="$_b" ;;
                        READ) bucket_read="$_b" ;;
                        MCP) bucket_mcp="$_b" ;;
                        OTHER) bucket_other="$_b" ;;
                    esac
                    ;;
                ACT)
                    # _a status, _b count, _c name, _d target
                    if [ "$_a" = "run" ]; then
                        _act="${ORANGE}◐${RESET} ${CYAN}${_c}${RESET}"
                        [ -n "$_d" ] && _act="${_act}${C_MUTED}: ${_d}${RESET}"
                    elif is_num "$_b" && [ "$_b" -gt 1 ]; then
                        _act="${GREEN}✓${RESET} ${CYAN}${_c}${RESET} ${C_ACCENT}×${_b}${RESET}"
                    else
                        _act="${GREEN}✓${RESET} ${CYAN}${_c}${RESET}"
                        [ -n "$_d" ] && _act="${_act}${C_MUTED}: ${_d}${RESET}"
                    fi
                    [ -n "$activity_value" ] && activity_value="${activity_value} | "
                    activity_value="${activity_value}${_act}"
                    ;;
                AGENT)
                    # _a start epoch, _b subagent type, _c model, _d description
                    _ag="${ORANGE}◐${RESET} ${CYAN}${_b}${RESET}"
                    [ -n "$_c" ] && _ag="${_ag} ${C_MUTED}[${_c}]${RESET}"
                    [ -n "$_d" ] && _ag="${_ag}${C_LABEL}:${RESET} ${_d}"
                    if is_num "$_a"; then
                        _el=$(fmt_elapsed_s $(( _now_epoch - _a )))
                        [ -n "$_el" ] && _ag="${_ag} ${C_MUTED}(${_el})${RESET}"
                    fi
                    [ -n "$agents_value" ] && agents_value="${agents_value} | "
                    agents_value="${agents_value}${_ag}"
                    ;;
                TODO)
                    # _a completed, _b total, _c current item text
                    if is_num "$_a" && is_num "$_b" && [ "$_b" -gt 0 ]; then
                        todo_value="${C_ACCENT}▸${RESET}"
                        [ -n "$_c" ] && todo_value="${todo_value} ${_c}"
                        todo_value="${todo_value} ${C_MUTED}(${_a}/${_b})${RESET}"
                    fi
                    ;;
            esac
        done < "$_tr_file"
        is_num "$session_total_input" || session_total_input=""
        is_num "$session_total_output" || session_total_output=""
    fi
fi

# ---------------------------------------------------------------------------
# Thinking (API) time, line diff, session duration
# ---------------------------------------------------------------------------
thinking_value=""
if is_num "$api_ms" && [ "${api_ms%.*}" -gt 0 ]; then
    thinking_value=$(fmt_duration_ms "$api_ms")
fi

la=${lines_added%.*}; is_num "$la" || la=0
lr=${lines_removed%.*}; is_num "$lr" || lr=0

session_dur_value=""
is_num "$dur_ms" && session_dur_value=$(fmt_duration_ms "$dur_ms")

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
        { [ -n "$_file" ] && [ -f "$_file" ]; } || continue
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
subscription_value=""
if [ "$IS_SUBSCRIPTION" -eq 1 ] && [ "$cfg_show_subscription" = "1" ]; then
    resolve_subscription_start_date
    case "$SUBSCRIPTION_DATE_STATE" in
        missing)
            subscription_warning_line="${BOLD_RED}${L_SUB_MISSING}${RESET}"
            ;;
        invalid)
            subscription_warning_line="${BOLD_RED}${L_SUB_INVALID}${RESET}"
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
                # Informational progress coloring, not a rate-limit warning:
                # green early, orange mid-cycle, red in the final ~2 days.
                if [ "$_sub_days_left" -le 2 ]; then _sub_color="$RED"
                elif [ "$_sub_pct" -ge 50 ]; then _sub_color="$ORANGE"
                else _sub_color="$GREEN"
                fi
                _sub_bar=$(render_bar "$_sub_pct" "$_sub_color")
                subscription_value="${_sub_bar} ${_sub_color}${_sub_pct}%${RESET} $(muted "${L_RESET} ${_sub_days_left}d")"
            fi
            ;;
    esac
fi

# ---------------------------------------------------------------------------
# Segments — every field renders into a named segment string (or stays empty,
# which drops it and its separator); the layout assembly at the bottom maps
# segments onto lines. Segment names are the config/layout vocabulary.
# ---------------------------------------------------------------------------

seg_model=""
if [ "$cfg_show_model" = "1" ] && [ -n "$model" ]; then
    seg_model="${C_MODEL}${L_MODEL} ${model}${RESET}"
    [ -n "$provider_badge" ] && seg_model="${seg_model} $(muted "[${provider_badge}]")"
fi

# Branch decorations (dirty marker, ahead/behind, file stats) build once here;
# they attach to the branch wherever it ends up rendering (combined or alone).
_branch_part=""
if [ "$cfg_show_branch" = "1" ] && [ -n "$git_branch" ]; then
    _branch_display="$git_branch"
    [ "$cfg_show_git_dirty" = "1" ] && [ "$git_dirty" = "1" ] && _branch_display="${_branch_display}*"
    _branch_part="${C_BRANCH}${_branch_display}${RESET}"
    if [ "$cfg_show_git_ahead_behind" = "1" ]; then
        if is_num "$git_ahead" && [ "$git_ahead" -gt 0 ]; then
            if [ "$git_ahead" -ge "$cfg_push_critical" ]; then _ab_color="$RED"
            elif [ "$git_ahead" -ge "$cfg_push_warning" ]; then _ab_color="$ORANGE"
            else _ab_color="$GREEN"
            fi
            _branch_part="${_branch_part} ${_ab_color}↑${git_ahead}${RESET}"
        fi
        if is_num "$git_behind" && [ "$git_behind" -gt 0 ]; then
            _branch_part="${_branch_part} $(muted "↓${git_behind}")"
        fi
    fi
    if [ "$cfg_show_git_file_stats" = "1" ]; then
        _stats=""
        is_num "$git_modified" && [ "$git_modified" -gt 0 ] && _stats="${_stats}${_stats:+ }!${git_modified}"
        is_num "$git_staged" && [ "$git_staged" -gt 0 ] && _stats="${_stats}${_stats:+ }+${git_staged}"
        is_num "$git_untracked" && [ "$git_untracked" -gt 0 ] && _stats="${_stats}${_stats:+ }?${git_untracked}"
        [ -n "$_stats" ] && _branch_part="${_branch_part} $(muted "${_stats}")"
    fi
fi

_worktree_part=""
if [ "$cfg_show_worktree" = "1" ] && [ -n "$worktree" ]; then
    _worktree_part="${C_BRANCH}${worktree}${RESET}"
fi

# Location renders as one "repo:branch/worktree" token. When the repo part is
# hidden/absent, branch and worktree fall back to their own segments so a
# custom layout or the minimal preset still shows them.
seg_repo=""; seg_branch=""; seg_worktree=""
_repo_part=""
if [ "$cfg_show_repo" = "1" ] && [ -n "$project_dir" ]; then
    _repo_display=$(path_tail "$project_dir" "$cfg_path_levels")
    [ -n "$_repo_display" ] && _repo_part="${C_REPO}${_repo_display}${RESET}"
fi
if [ -n "$_repo_part" ]; then
    seg_repo="$_repo_part"
    [ -n "$_branch_part" ] && seg_repo="${seg_repo}:${_branch_part}"
    [ -n "$_worktree_part" ] && seg_repo="${seg_repo}/${_worktree_part}"
else
    seg_branch="$_branch_part"
    seg_worktree="$_worktree_part"
fi

# Straight from Claude Code's own cost.total_lines_added/removed — this only
# reflects edits made by this session's own tools (not sub-agents or nested
# repos), but it's what Claude Code itself reports, so it's never stale.
seg_lines_changed=""
if [ "$cfg_show_lines_changed" = "1" ]; then
    if [ "$la" -gt 0 ] || [ "$lr" -gt 0 ]; then
        seg_lines_changed="${GREEN}+${la}${RESET} ${RED}-${lr}${RESET}"
    fi
fi

seg_version=""
if [ "$cfg_show_version" = "1" ] && [ -n "$cc_version" ]; then
    seg_version="$(muted "v${cc_version}")"
fi

seg_subscription="$subscription_value"
[ -n "$seg_subscription" ] && seg_subscription="${C_LABEL}${L_SUBSCRIPTION}${RESET} ${seg_subscription}"

# Sessions: 5h / Nd usage (Nd = actual days remaining until the weekly window
# resets, computed live — not hardcoded to "7d", since it's a rolling window).
# Bars are colored to match their usage color (green/orange/red). Reset
# strings are the bare countdown; only the weekly reset appends its absolute
# date, and only once it's more than a day out (a same-day reset's countdown
# already says everything).
seg_sessions=""
if [ "$IS_SUBSCRIPTION" -eq 1 ] && [ "$cfg_show_sessions" = "1" ]; then
    five_pct=${five_util_probe%.*}; is_num "$five_pct" || five_pct=0
    seven_pct=${seven_util_probe%.*}; is_num "$seven_pct" || seven_pct=0

    five_color=$(usage_color "$five_pct" "$cfg_5h_warn" "$cfg_5h_crit")
    seven_color=$(usage_color "$seven_pct" "$cfg_7d_warn" "$cfg_7d_crit")

    five_bar=$(render_bar "$five_pct" "$five_color")
    seven_bar=$(render_bar "$seven_pct" "$seven_color")

    five_reset_countdown=$(fmt_countdown_epoch "$five_reset")
    seven_reset_countdown=$(fmt_countdown_epoch "$seven_reset")
    seven_reset_date=$(format_date_epoch "$seven_reset")

    seven_days_label="7d"
    _seven_days_left=""
    seven_reset_int=${seven_reset%.*}
    if is_num "$seven_reset_int"; then
        now_epoch=$(date +%s)
        _diff=$(( seven_reset_int - now_epoch ))
        [ "$_diff" -lt 0 ] && _diff=0
        # Ceiling division: partial days round up (e.g. 18h left -> "1d", 4.2 days -> "5d")
        _seven_days_left=$(( (_diff + 86399) / 86400 ))
        seven_days_label="${_seven_days_left}d"
    fi

    seg_sessions="${C_LABEL}${L_FIVE_HOUR}${RESET} ${five_bar} ${five_color}${five_pct}%${RESET}"
    [ -n "$five_reset_countdown" ] && seg_sessions="${seg_sessions} $(muted "${L_RESET} ${five_reset_countdown}")"

    seg_sessions="${seg_sessions} $(muted "|") ${C_LABEL}${seven_days_label}${RESET} ${seven_bar} ${seven_color}${seven_pct}%${RESET}"
    if [ -n "$seven_reset_countdown" ]; then
        _seven_reset="${L_RESET} ${seven_reset_countdown}"
        if [ -n "$seven_reset_date" ] && is_num "$_seven_days_left" && [ "$_seven_days_left" -gt 1 ]; then
            _seven_reset="${_seven_reset} [${seven_reset_date}]"
        fi
        seg_sessions="${seg_sessions} $(muted "${_seven_reset}")"
    fi
fi

# OpenRouter live balance from /api/v1/credits, 60s cache, timeout-bounded so
# a slow/down API never blocks the render. Both total and remaining are read
# live — never hardcoded — so top-ups are reflected automatically. The cache
# needs no per-key filename: the whole cache root is already per-user private.
seg_balance=""
if [ "$IS_OPENROUTER" -eq 1 ] && [ "$cfg_show_balance" = "1" ] && [ -n "$OPENROUTER_API_KEY" ] && command -v curl >/dev/null 2>&1; then
    _or_dir="$CACHE_ROOT/openrouter-cache"
    mkdir -p "$_or_dir"
    _or_file="$_or_dir/credits.json"
    _or_stamp="$_or_dir/credits.stamp"
    _or_do_fetch=1
    if [ -f "$_or_stamp" ]; then
        _or_age=$(( $(date +%s) - $(file_mtime "$_or_stamp") ))
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
        IFS=$'\t' read -r or_total or_used <<< "$(jq -r '[(.data.total_credits // ""), (.data.total_usage // "")] | @tsv' "$_or_file" 2>/dev/null)"
        if is_num "$or_total" && is_num "$or_used"; then
            or_remaining=$(awk "BEGIN{printf \"%.2f\", $or_total - $or_used}")
            or_used_pct=$(awk "BEGIN{ if ($or_total > 0) printf \"%.0f\", ($or_used/$or_total)*100; else print 0 }")
            or_color=$(usage_color "$or_used_pct" "$cfg_5h_warn" "$cfg_5h_crit")
            or_bar=$(render_bar "$or_used_pct" "$or_color")
            seg_balance="${C_LABEL}${L_BALANCE}${RESET} ${or_bar} ${or_color}${or_used_pct}%${RESET} $(muted "\$$(printf "%.2f" "$or_remaining")/\$$(printf "%.2f" "$or_total")")"
        fi
    fi
fi

# Context segment — which value(s) render next to the bar is configurable:
# percent | tokens | remaining (tokens left before auto-compact) | both.
seg_context=""
if [ "$cfg_show_context" = "1" ]; then
    _ctx_bar=$(render_bar "$pct" "$pct_color")
    case "$cfg_context_value" in
        percent)
            seg_context="${C_LABEL}${L_CONTEXT}${RESET} ${_ctx_bar} ${pct_color}${pct}%${RESET}"
            ;;
        tokens)
            seg_context="${C_LABEL}${L_CONTEXT}${RESET} ${_ctx_bar} $(muted "${token_used_k}k/${token_max_k}k")"
            ;;
        remaining)
            seg_context="${C_LABEL}${L_CONTEXT}${RESET} ${_ctx_bar} $(muted "${remaining_k}k ${L_LEFT}")"
            ;;
        both|*)
            seg_context="${C_LABEL}${L_CONTEXT}${RESET} ${_ctx_bar} ${pct_color}${pct}%${RESET} $(muted "${token_used_k}k/${token_max_k}k")"
            ;;
    esac
fi

seg_cost=""
if [ "$cfg_show_cost" = "1" ] && is_num "$cost_usd"; then
    # On subscription mode this figure is computed at standard API list rates
    # and has no relationship to the flat monthly fee actually billed — it's
    # an API-equivalent estimate. On API-key/OpenRouter mode it IS real spend.
    _cost_label="$L_COST"
    [ "$IS_SUBSCRIPTION" -eq 1 ] && _cost_label="$L_COST_EST"
    seg_cost="$(muted "${_cost_label}") ${C_ACCENT}\$$(printf "%.2f" "$cost_usd")${RESET}"
fi

seg_total_tokens=""
if [ "$cfg_show_total_tokens" = "1" ] && is_num "$session_total_input" && is_num "$session_total_output"; then
    _in_fmt=$(fmt_tokens_k "$session_total_input")
    _out_fmt=$(fmt_tokens_k "$session_total_output")
    seg_total_tokens="$(muted "${L_TOTAL_TOKENS} ${_in_fmt}/${_out_fmt}")"
fi

seg_loc=""
if [ -n "$loc_value" ]; then
    seg_loc="$(muted "${L_LOC} ${loc_value}")"
fi

seg_session_time=""
if [ "$cfg_show_session_time" = "1" ] && [ -n "$session_dur_value" ]; then
    seg_session_time="$(muted "${L_SESSION_TIME} ${session_dur_value}")"
fi

seg_thinking_time=""
if [ "$cfg_show_thinking_time" = "1" ] && [ -n "$thinking_value" ]; then
    seg_thinking_time="$(muted "${L_THINKING} ${thinking_value}")"
fi

# Cache ratio + efficiency grade.
# Efficiency denominator is edit-capable tool calls only (the Code bucket) —
# counting read-only tools dragged exploration-heavy sessions toward F even
# when tool use was entirely appropriate. No edits yet -> the field is omitted
# rather than showing a misleading F(0).
# Cache % is deliberately muted, not threshold-colored: it's informational,
# and warning colors are reserved for actionable fields.
seg_cache_ratio=""
if [ "$cfg_show_cache_ratio" = "1" ] && [ "$token_total" -gt 0 ]; then
    cache_ratio=$(( ${token_cr%.*} * 100 / token_total ))
    seg_cache_ratio="$(muted "${L_CACHE_RATIO} ${cache_ratio}%")"
fi

seg_efficiency=""
if [ "$cfg_show_efficiency" = "1" ] && is_num "$bucket_code" && [ "$bucket_code" -gt 0 ]; then
    lines_changed=$(( la + lr ))
    eff_score=$(( lines_changed * 40 / bucket_code ))
    [ "$eff_score" -gt 100 ] && eff_score=100
    eff_grade=$(grade_for "$eff_score")
    eff_color=$(grade_color "$eff_grade")
    seg_efficiency="$(muted "${L_EFFICIENCY}") ${eff_color}${eff_grade}(${eff_score})${RESET}"
fi

# One consolidated diagnostics clause: total plus only the non-zero buckets
# (the bucket sum still equals the total by construction — zero buckets are
# just not spelled out anymore).
seg_tool_calls=""
if [ "$cfg_show_tool_calls" = "1" ] && is_num "$tool_calls_total" && [ "$tool_calls_total" -gt 0 ]; then
    _buckets=""
    for _bpair in "$L_BUCKET_COMMANDS:$bucket_commands" "$L_BUCKET_READ:$bucket_read" \
                  "$L_BUCKET_CODE:$bucket_code" "$L_BUCKET_SKILLS:$bucket_skills" \
                  "$L_BUCKET_MCP:$bucket_mcp" "$L_BUCKET_OTHER:$bucket_other"; do
        _bcount="${_bpair##*:}"
        { is_num "$_bcount" && [ "$_bcount" -gt 0 ]; } || continue
        _buckets="${_buckets}${_buckets:+, }${_bpair%%:*} ${_bcount}"
    done
    seg_tool_calls="${L_TOOL_CALLS} ${tool_calls_total}"
    [ -n "$_buckets" ] && seg_tool_calls="${seg_tool_calls} (${_buckets})"
    seg_tool_calls="$(muted "$seg_tool_calls")"
fi

seg_activity=""
if [ "$cfg_show_activity" = "1" ] && [ -n "$activity_value" ]; then
    seg_activity="${C_LABEL}${L_ACTIVITY}${RESET} ${activity_value}"
fi

seg_agents=""
if [ "$cfg_show_agents" = "1" ] && [ -n "$agents_value" ]; then
    seg_agents="${C_LABEL}${L_AGENTS}${RESET} ${agents_value}"
fi

seg_todos=""
if [ "$cfg_show_todos" = "1" ] && [ -n "$todo_value" ]; then
    seg_todos="${C_LABEL}${L_TODO}${RESET} ${todo_value}"
fi

# Only rendered while something is actually still in flight (mirrors the
# hide-when-idle convention on Agents:/Todo: above) — a fully merged/committed
# run drops off instead of lingering as stale "all done" state forever.
seg_orchestrator=""
if [ "$cfg_show_orchestrator" = "1" ]; then
    if [ "$orca_total" -gt 0 ] && [ "$orca_merged" -lt "$orca_total" ]; then
        seg_orchestrator="${C_LABEL}${L_ORCA}${RESET} ${GREEN}${orca_merged}/${orca_total} merged${RESET}"
        [ "$orca_inprogress" -gt 0 ] && seg_orchestrator="${seg_orchestrator} | ${CYAN}${orca_inprogress} in progress${RESET}"
        [ "$orca_done" -gt 0 ] && seg_orchestrator="${seg_orchestrator} | ${C_ACCENT}${orca_done} done${RESET}"
        [ "$orca_conflict" -gt 0 ] && seg_orchestrator="${seg_orchestrator} | ${RED}${orca_conflict} conflict ⚠${RESET}"
        [ "$orca_blocked" -gt 0 ] && seg_orchestrator="${seg_orchestrator} | ${RED}${orca_blocked} blocked${RESET}"
    elif [ "$master_total" -gt 0 ] && [ "$master_committed" -lt "$master_total" ] && [ -n "$master_open_num" ]; then
        seg_orchestrator="${C_LABEL}${L_MASTER}${RESET} ${C_ACCENT}Stage ${master_open_num}/${master_total}${RESET} ${CYAN}${master_open_status}${RESET}"
        [ -n "$master_open_title" ] && seg_orchestrator="${seg_orchestrator} — ${master_open_title}"
        if [ -n "$master_open_spawned" ]; then
            _mo_epoch=$(parse_iso_epoch "$master_open_spawned")
            if is_num "$_mo_epoch"; then
                _mo_elapsed=$(( $(date +%s) - ${_mo_epoch%.*} ))
                [ "$_mo_elapsed" -ge 0 ] && seg_orchestrator="${seg_orchestrator} (${C_MUTED}$(fmt_elapsed_s "$_mo_elapsed")${RESET})"
            fi
        fi
        [ "$master_committed" -gt 0 ] && seg_orchestrator="${seg_orchestrator} | ${GREEN}${master_committed} committed${RESET}"
    fi
fi

segment_value() {
    case "$1" in
        model) printf '%s' "$seg_model" ;;
        repo) printf '%s' "$seg_repo" ;;
        branch) printf '%s' "$seg_branch" ;;
        worktree) printf '%s' "$seg_worktree" ;;
        lines_changed) printf '%s' "$seg_lines_changed" ;;
        version) printf '%s' "$seg_version" ;;
        subscription) printf '%s' "$seg_subscription" ;;
        sessions) printf '%s' "$seg_sessions" ;;
        balance) printf '%s' "$seg_balance" ;;
        context) printf '%s' "$seg_context" ;;
        cost) printf '%s' "$seg_cost" ;;
        total_tokens) printf '%s' "$seg_total_tokens" ;;
        loc) printf '%s' "$seg_loc" ;;
        session_time) printf '%s' "$seg_session_time" ;;
        thinking_time) printf '%s' "$seg_thinking_time" ;;
        cache_ratio) printf '%s' "$seg_cache_ratio" ;;
        efficiency) printf '%s' "$seg_efficiency" ;;
        tool_calls) printf '%s' "$seg_tool_calls" ;;
        activity) printf '%s' "$seg_activity" ;;
        agents) printf '%s' "$seg_agents" ;;
        todos) printf '%s' "$seg_todos" ;;
        orchestrator) printf '%s' "$seg_orchestrator" ;;
    esac
}

# ---------------------------------------------------------------------------
# Assembly + output — warning lines first, then the layout's lines with empty
# segments (and fully-empty lines) dropped. Lines are width-truncated with a
# trailing "…" when a width is known: $COLUMNS if exported, else the config's
# max_width; ANSI escapes are excluded from the width count. printf uses %s
# (data), never re-parses content as a format string, so literal '%'
# characters anywhere in the values can never break printf.
# ---------------------------------------------------------------------------
layout_spec="$LAYOUT_EXPANDED"
[ "$cfg_layout" = "compact" ] && layout_spec="$LAYOUT_COMPACT"
[ -n "$cfg_lines" ] && layout_spec="$cfg_lines"

out_lines=()
[ -n "$config_warning_line" ] && out_lines+=("$config_warning_line")
[ -n "$subscription_warning_line" ] && out_lines+=("$subscription_warning_line")

IFS='|' read -ra _layout_line_specs <<< "$layout_spec"
for _lspec in "${_layout_line_specs[@]}"; do
    _line=""
    IFS=',' read -ra _seg_names <<< "$_lspec"
    for _sn in "${_seg_names[@]}"; do
        _sv=$(segment_value "$_sn")
        [ -n "$_sv" ] || continue
        [ -n "$_line" ] && _line+=" ${C_MUTED}|${RESET} "
        _line+="$_sv"
    done
    [ -n "$_line" ] && out_lines+=("$_line")
done

term_width=0
if is_num "${COLUMNS:-}" && [ "${COLUMNS:-0}" -gt 0 ]; then
    term_width=$COLUMNS
fi
if [ "$cfg_max_width" -gt 0 ]; then
    if [ "$term_width" -eq 0 ] || [ "$term_width" -gt "$cfg_max_width" ]; then
        term_width=$cfg_max_width
    fi
fi

if [ "${#out_lines[@]}" -gt 0 ]; then
    if [ "$term_width" -gt 0 ]; then
        # Byte-oriented awks (BSD awk, mawk) see UTF-8 continuation bytes as
        # separate "characters"; the cont[] table marks them so multi-byte
        # glyphs count as width 1 and are never split mid-sequence. In
        # char-oriented gawk the table simply never matches, which is also
        # correct. ANSI escapes are copied through without counting.
        printf '%s\n' "${out_lines[@]}" | awk -v max="$term_width" '
        BEGIN { for (b = 128; b < 192; b++) cont[sprintf("%c", b)] = 1 }
        function visible_width(s,    i, n, c, w, r) {
            n = length(s); i = 1; w = 0
            while (i <= n) {
                c = substr(s, i, 1)
                if (c == "\033") {
                    r = substr(s, i)
                    if (match(r, /^\033\[[0-9;]*m/)) { i += RLENGTH; continue }
                }
                if (!(c in cont)) w++
                i++
            }
            return w
        }
        {
            line = $0
            if (visible_width(line) <= max) { print line; next }
            out = ""; vis = 0; i = 1; n = length(line)
            while (i <= n) {
                c = substr(line, i, 1)
                if (c == "\033") {
                    rest = substr(line, i)
                    if (match(rest, /^\033\[[0-9;]*m/)) {
                        out = out substr(rest, 1, RLENGTH)
                        i += RLENGTH
                        continue
                    }
                }
                if (c in cont) { out = out c; i++; continue }
                if (vis >= max - 1) break
                out = out c; vis++; i++
            }
            print out "…\033[0m"
        }'
    else
        printf '%s\n' "${out_lines[@]}"
    fi
fi

exit 0
