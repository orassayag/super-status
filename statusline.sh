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
# Teal-mint (256-color), not ANSI green — "healthy" and the identity accent
# share this one tone per the redesign, instead of the terminal theme's
# (often much brighter) palette green.
GREEN=$'\033[38;5;43m'
GREY=$'\033[90m'
WHITE=$'\033[37m'
RED=$'\033[31m'
BOLD_RED=$'\033[1;31m'
ORANGE=$'\033[38;5;208m'

# ---------------------------------------------------------------------------
# Config defaults — a missing/empty config.json yields exactly these, which
# reproduce the pre-config behavior of this script. New-in-2.0 elements
# (activity/agents/todos lines, git dirty/ahead-behind/file-stats markers)
# therefore default OFF; enable them per key or via "preset": "full".
# ---------------------------------------------------------------------------
cfg_language="en"
cfg_layout="expanded"
# Bar glyphs deliberately don't span the full cell height (▮/▪, not ▐/▒/█) —
# full-height glyphs on adjacent lines touch vertically and read as one wall.
cfg_bar_width=10
cfg_bar_filled="▮"
cfg_bar_empty="▪"
cfg_path_levels=1
cfg_max_width=0
cfg_context_value="both"
cfg_lines=""
# Context % is measured against this window when it's a positive token count
# (matches the number `/context` shows, which is the auto-compact threshold, not
# the full model window). 0 = disabled, keep measuring against the full window.
cfg_auto_compact_window=0
# model_source picks where the model NAME comes from behind a proxy:
#   stdin      — always trust the stdin display_name (default)
#   transcript — read the real model id from the session transcript
#   auto       — use the transcript only when a non-Anthropic backend is detected
cfg_model_source="stdin"
# Optional local usage snapshot: a JSON file another tool writes with the same
# shape as stdin's `rate_limits` (plus an optional `model_scoped` map). When
# stdin omits rate_limits, a snapshot fresher than external_usage_max_age
# seconds fills the 5h/Nd bars. 0 path = disabled.
cfg_external_usage_path=""
cfg_external_usage_max_age=1800
# Parameter-count badge rendered after the model name ("◆ Sonnet 5 (365B)").
# Anthropic publishes no parameter counts for Claude models, so there is no
# built-in table: this is a user-declared "model_params" map from a
# case-insensitive substring of the displayed model name to the text to show.
cfg_model_params_patterns=()
cfg_model_params_labels=()
# Per-MTok list-rate overrides for the local spend estimate, "pattern": "in/out"
# (e.g. {"opus-5": "5/25"}). Matching is the same longest-substring-of-the-model-id
# rule as model_params. Empty = the estimator's built-in table, which is Anthropic
# list pricing at the time of writing and will drift as rates change.
cfg_model_pricing_patterns=()
cfg_model_pricing_labels=()
# Account-mode badge — the identity line's leading segment ("API | ◆ Opus 5").
# Auto-detection reads ~/.claude.json's oauthAccount.{billingType,seatTier}:
# billingType separates API billing from a subscription, but seatTier — the only
# thing that names Pro vs. Max — is null on most accounts, so plan_label is the
# override that makes the tier visible.
cfg_plan_label=""
# Prepaid API credit bar. Anthropic publishes no credit-balance endpoint (the
# Console's "Credit balance" card is not in the public API), so the balance is a
# user-declared snapshot and everything spent since it comes from the Admin API
# cost report. Empty balance = the whole feature is inert.
cfg_api_credit_balance=""
cfg_api_credit_as_of=""
cfg_api_spend_cache_seconds=300
# Seconds any single git (or jj) call may take before it is abandoned and the
# segment degrades to "no repository here". Generous for local git, still well
# inside a two-second refresh.
cfg_git_timeout=3
# Jujutsu. Off by default, and even when on it only takes over for a repository
# that actually holds a .jj control directory — one system per repository,
# never both on the line at once.
cfg_jj_enabled=0
# Extra working directories from /add-dir. added_dirs_layout is "inline"
# (`super-status:main +shared-lib`) or "line" (a separate `Added dirs:` row).
cfg_added_dirs_max=5
cfg_added_dirs_name_width=24
cfg_added_dirs_layout="inline"
# Prompt-cache expiry. The tier is read from the transcript (a 5-minute vs.
# 1-hour cache write); this is only the fallback for transcripts that record
# neither, and never overrides one that does.
cfg_prompt_cache_ttl_seconds=300
# Opt-in producer side of external_usage_path: the authoritative rate-limit
# windows that arrive free on stdin, written out for another tool to read.
cfg_external_usage_write_path=""
# OSC 8 hyperlinks on the activity line's file names.
cfg_hyperlinks=0
# Segment name at which a line's right-aligned run begins, as "line_index:name"
# pairs are not needed — a bare segment name is matched on whichever line it
# renders. Empty = every line packs left, as before.
cfg_right_align=""

cfg_show_model=1
cfg_show_mode=1
cfg_show_repo=1
cfg_show_branch=1
cfg_show_worktree=1
cfg_show_lines_changed=1
cfg_show_version=1
cfg_show_git_dirty=0
cfg_show_git_ahead_behind=0
cfg_show_git_file_stats=0
cfg_show_provider=1
cfg_show_effort=1
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
cfg_show_added_dirs=0
cfg_show_prompt_cache=0
cfg_show_today=0
cfg_show_compactions=0
cfg_show_speed=0

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
LAYOUT_EXPANDED="mode,model,agent,repo,branch,worktree,lines_changed,version|added_dirs|subscription,sessions,balance|context,cache_ratio,prompt_cache,cost,today,total_tokens|loc,session_time,thinking_time,speed,efficiency,tool_calls,compactions|activity|agents|todos|orchestrator"
LAYOUT_COMPACT="mode,model,agent,repo,branch,worktree,added_dirs,context|subscription,sessions,balance,cost,today|activity,agents,todos,orchestrator"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
is_num() { [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; }

# SUPER_STATUS_DEBUG=1 traces where each value came from and why a segment came
# out empty. Standard ERROR, never standard output: the statusline IS standard
# output, so a trace written there would corrupt the display it is explaining.
# This answers "why is this render empty"; doctor.sh answers "is the install
# correct" — the two do not overlap.
debug_log() {
    if [ "${SUPER_STATUS_DEBUG:-0}" = "1" ]; then
        printf 'super-status: %s\n' "$*" >&2
    fi
    return 0
}

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

# Turn a raw model id into a readable display name:
#   claude-sonnet-4-6-20250101 -> Claude Sonnet 4.6
#   claude-3-5-haiku-20241022  -> Claude 3.5 Haiku
# Strips a trailing yyyymmdd date, drops any vendor "provider." prefix (Bedrock/
# Vertex prefix the id), joins numeric segments with a dot, and Title-Cases the
# rest. An id that doesn't look like a Claude model is returned unchanged.
humanize_model_id() {
    local raw="$1" id part out=""
    [ -n "$raw" ] || { echo ""; return; }
    id="${raw##*/}"          # strip vertex "publishers/.../models/ID" paths
    # Strip leading "region.provider." segments (Bedrock, e.g. "us.anthropic.claude-...")
    # one dot-segment at a time, stopping once the remaining segment is itself the
    # model name — so a version dot in "gemini-1.5-pro" is never mistaken for one.
    while [[ "$id" == *.* && "${id%%.*}" != *claude* && "${id%%.*}" != *gemini* ]]; do
        id="${id#*.}"
    done
    case "$id" in
        *claude*|*gemini*) ;;
        *) echo "$raw"; return ;;
    esac
    id="${id%-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]}"   # trailing yyyymmdd
    local prev_num=0
    local parts=()
    IFS='-' read -ra parts <<< "$id"
    for part in "${parts[@]}"; do
        [ -n "$part" ] || continue
        if [[ "$part" =~ ^[0-9]+$ ]]; then
            if [ "$prev_num" -eq 1 ]; then out="${out}.${part}"; else out="${out} ${part}"; fi
            prev_num=1
        elif [ "$part" = "high" ] || [ "$part" = "medium" ] || [ "$part" = "low" ]; then
            out="${out} ($(tr '[:lower:]' '[:upper:]' <<< "${part:0:1}")${part:1})"
            prev_num=0
        else
            out="${out} $(tr '[:lower:]' '[:upper:]' <<< "${part:0:1}")${part:1}"
            prev_num=0
        fi
    done
    echo "${out# }"
}

# Parameter-count badge for a displayed model name, from the user-declared
# model_params map. Matching is case-insensitive substring and the longest
# matching pattern wins, so a specific "sonnet 5" beats a broader "sonnet"
# regardless of the order they appear in config.json.
model_params_label() {
    local name="$1" lname idx pattern best="" best_len=0
    [ -n "$name" ] || { echo ""; return; }
    lname=$(tr '[:upper:]' '[:lower:]' <<< "$name")
    for idx in "${!cfg_model_params_patterns[@]}"; do
        pattern=$(tr '[:upper:]' '[:lower:]' <<< "${cfg_model_params_patterns[$idx]}")
        [ -n "$pattern" ] || continue
        case "$lname" in
            *"$pattern"*)
                if [ "${#pattern}" -gt "$best_len" ]; then
                    best="${cfg_model_params_labels[$idx]}"
                    best_len=${#pattern}
                fi
                ;;
        esac
    done
    echo "$best"
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

# Anthropic seat-tier id -> display text: "max_20x" -> "Max 20x", "pro" -> "Pro".
# An id this doesn't recognize is Title-Cased word by word rather than dropped,
# so a tier introduced after this ships still renders something truthful.
seat_tier_label() {
    local _raw="$1" _word _out=""
    { [ -n "$_raw" ] && [ "$_raw" != "null" ]; } || return
    for _word in ${_raw//_/ }; do
        case "$_word" in
            [0-9]*[xX]) _out+=" $(tr '[:upper:]' '[:lower:]' <<<"$_word")" ;;
            *) _out+=" $(tr '[:lower:]' '[:upper:]' <<<"${_word:0:1}")${_word:1}" ;;
        esac
    done
    printf '%s' "${_out# }"
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

# Bare "dd/MM" for a date that is a calendar day rather than a moment — the
# credit snapshot. Deliberately not format_reset_marker, which collapses today
# to a clock time: correct for a reset that is hours away, nonsense for a
# snapshot taken at midnight, which would read "as of 00:00".
format_day_month_epoch() {
    local epoch="$1"
    is_num "$epoch" || { echo ""; return; }
    date -d "@${epoch%.*}" +"%d/%m" 2>/dev/null || date -r "${epoch%.*}" +"%d/%m" 2>/dev/null || echo ""
}

# dd/MM/yyyy only — used for the subscription cycle renewal date and the
# weekly reset date.
format_date_epoch() {
    local epoch="$1"
    is_num "$epoch" || { echo ""; return; }
    date -d "@${epoch%.*}" +"%d/%m/%Y" 2>/dev/null || date -r "${epoch%.*}" +"%d/%m/%Y" 2>/dev/null || echo ""
}

# epoch -> "YYYY-MM-DDT00:00:00Z", the `starting_at` the Admin API cost report
# takes. Deliberately reads the epoch's LOCAL calendar date and pins that date
# to the UTC boundary the report snaps its buckets to: the epoch comes from
# parse_subscription_date, i.e. local midnight on the date the user declared, so
# re-rendering it in UTC would move the window a day west of that date in every
# zone ahead of UTC and silently bill an extra day's spend against the snapshot.
format_cost_report_start() {
    local epoch="$1" _day
    is_num "$epoch" || { echo ""; return; }
    _day=$(date -d "@${epoch%.*}" +"%Y-%m-%d" 2>/dev/null || date -r "${epoch%.*}" +"%Y-%m-%d" 2>/dev/null)
    [ -n "$_day" ] && printf '%sT00:00:00Z' "$_day"
}

# Absolute "when" marker paired with a relative reset countdown: "HH:MM" when the
# reset lands on today's calendar date (a clock time is enough), "dd/MM" when it
# lands on a later day (the countdown alone no longer makes the day obvious).
# A second "clock" argument forces "HH:MM" regardless of day — used for the 5h
# window, which is always under five hours away, so the wall-clock reset time is
# the meaningful marker even when it crosses midnight (a "dd/MM" date there is
# misleading: it reads as days away, not hours).
# Same BSD/GNU date dual-command fallback as format_date_epoch.
format_reset_marker() {
    local epoch="$1" mode="$2"
    is_num "$epoch" || { echo ""; return; }
    local target="${epoch%.*}" target_day today
    if [ "$mode" = "clock" ]; then
        date -d "@${target}" +"%H:%M" 2>/dev/null || date -r "${target}" +"%H:%M" 2>/dev/null || echo ""
        return
    fi
    target_day=$(date -d "@${target}" +"%Y%m%d" 2>/dev/null || date -r "${target}" +"%Y%m%d" 2>/dev/null) || return
    today=$(date +"%Y%m%d")
    if [ "$target_day" = "$today" ]; then
        date -d "@${target}" +"%H:%M" 2>/dev/null || date -r "${target}" +"%H:%M" 2>/dev/null || echo ""
    else
        date -d "@${target}" +"%d/%m" 2>/dev/null || date -r "${target}" +"%d/%m" 2>/dev/null || echo ""
    fi
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

# Credit-snapshot moment: "dd/MM/yyyy" (midnight) or "dd/MM/yyyy HH:MM" (that
# minute). A balance read off the Console is true at an instant, not for a whole
# day — anchoring an afternoon reading to midnight would re-subtract everything
# already spent that day, so /super-status:credits records the clock time and
# this accepts it. The bare-date form stays valid and means midnight, which is
# what backdating a top-up to a past day should mean.
parse_snapshot_moment() {
    local _raw _date _clock _epoch _hour _minute
    _raw=$(trim_ws "$1")
    _date="${_raw%% *}"
    _epoch=$(parse_subscription_date "$_date")
    [ -n "$_epoch" ] || return
    if [ "$_raw" != "$_date" ]; then
        _clock=$(trim_ws "${_raw#"$_date"}")
        [[ "$_clock" =~ ^([0-2][0-9]):([0-5][0-9])$ ]] || return
        _hour=$(( 10#${BASH_REMATCH[1]} ))
        _minute=$(( 10#${BASH_REMATCH[2]} ))
        [ "$_hour" -le 23 ] || return
        _epoch=$(( _epoch + _hour * 3600 + _minute * 60 ))
    fi
    printf '%s' "$_epoch"
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
    # Empty cells default to muted gray, not the usage color — the colored
    # part of the bar is the signal; the remainder is just scale.
    printf '%s' "${C_BAR_FILLED:-$outer}${fstr}${RESET}${C_BAR_EMPTY:-$C_MUTED}${estr}${RESET}"
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

file_size() {
    stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null || echo 0
}

trim_ws() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Bidi overrides and the invisible direction marks, written as literal UTF-8
# byte sequences rather than \u escapes: macOS ships bash 3.2, which has no \u.
SANITIZE_BIDI=(
    $'\xe2\x80\x8e' $'\xe2\x80\x8f'
    $'\xe2\x80\xaa' $'\xe2\x80\xab' $'\xe2\x80\xac' $'\xe2\x80\xad' $'\xe2\x80\xae'
    $'\xe2\x81\xa6' $'\xe2\x81\xa7' $'\xe2\x81\xa8' $'\xe2\x81\xa9'
)
# CSI ("ESC [ ... final"), OSC ("ESC ] ... BEL/ST"), then any other
# ESC-introduced two-character sequence. No branch can match the empty string,
# so the removal loop in sanitize_text always terminates.
SANITIZE_ESC_RE=$'\033\\[[0-9;?]*[ -/]*[@-~]|\033\\][^\a\033]*(\a|\033\\\\)?|\033[@-_]?'

# Every string this script did not author itself — a file name or tool argument
# out of the transcript, a path on disk, a model name, a label from an external
# snapshot — reaches a terminal that obeys escape sequences, so all of it is
# routed through here first. Whole escape sequences go before the remaining
# control characters, so truncation can never leave half a sequence behind, and
# the visible width the max_width pass counts is the width actually printed.
# Pure bash on purpose: this runs on a dozen values every render.
sanitize_text() {
    local _s="$1" _m
    while [[ "$_s" =~ $SANITIZE_ESC_RE ]]; do
        _m="${BASH_REMATCH[0]}"
        _s="${_s/"$_m"/}"
    done
    for _m in "${SANITIZE_BIDI[@]}"; do
        _s="${_s//"$_m"/}"
    done
    trim_ws "${_s//[[:cntrl:]]/ }"
}

# OSC 8 terminal hyperlink around $2, addressed by $1. The address is built
# here from a path this script resolved, never passed through from outside, and
# is percent-escaped and re-sanitized anyway: a hyperlink embeds its address in
# an escape sequence, which is precisely the output class sanitize_text exists
# to close. Anything that fails validation renders as plain text.
safe_hyperlink() {
    # LC_ALL=C so the loop walks bytes, not characters: a percent-escape is
    # defined per byte, and a multi-byte path encoded per character is wrong.
    local LC_ALL=C
    local _path="$1" _label="$2" _enc="" _hex="" _c _i
    [ -n "$_label" ] || return 1
    _path=$(sanitize_text "$_path")
    case "$_path" in
        /*) ;;
        *) return 1 ;;
    esac
    for (( _i = 0; _i < ${#_path}; _i++ )); do
        _c="${_path:_i:1}"
        case "$_c" in
            [A-Za-z0-9/._~-]) _enc+="$_c" ;;
            # A byte at or above 0x80 comes back sign-extended from printf's
            # "'c" form (FFFFFFFFFFFFFFC3, not C3), so only the low byte is kept.
            *) printf -v _hex '%02X' "'$_c"; _enc+="%${_hex: -2}" ;;
        esac
    done
    # shellcheck disable=SC1003  # \\ is the ST terminator's backslash, not a quote escape
    printf '\033]8;;file://%s\033\\%s\033]8;;\033\\' "$_enc" "$_label"
}

# UTC ISO-8601 (e.g. "2026-07-17T10:00:00Z") -> epoch seconds. Same BSD/GNU
# dual-command fallback as parse_subscription_date above; prints nothing on
# unparseable input rather than failing the caller.
parse_iso_epoch() {
    local _t="$1"
    date -d "$_t" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$_t" +%s 2>/dev/null
}

# Total USD spent since $1 (an RFC 3339 day boundary), from the Admin API cost
# report, printed to stdout; non-zero exit means "no trustworthy figure", which
# callers must not read as zero spend. $2 is an Admin API key (sk-ant-admin...),
# which is a different credential from ANTHROPIC_API_KEY. Lives above the source
# guard only so tests can drive it with a stubbed `curl`; it is the one function
# up here that touches the network, and no caller runs it inline — see the
# credit-bar block in the render flow for why it is always backgrounded.
anthropic_spend_usd() {
    local _start_iso="$1" _key="$2"
    local _page="" _url _resp _sum=0 _partial _has_more="" _pages=0
    while [ "$_pages" -lt 12 ]; do
        _url="https://api.anthropic.com/v1/organizations/cost_report?starting_at=${_start_iso}&bucket_width=1d&limit=31"
        [ -n "$_page" ] && _url="${_url}&page=${_page}"
        _resp=$(curl -s --max-time 10 "$_url" \
            -H "anthropic-version: 2023-06-01" \
            -H "x-api-key: ${_key}" \
            -H "User-Agent: super-status (https://github.com/orassayag/super-status)" 2>/dev/null)
        [ -n "$_resp" ] || return 1
        # An error body (rejected key, individual account with no org) carries no
        # .data array. Bail rather than record its absence as a real zero spend.
        IFS=$'\t' read -r _partial _has_more _page <<< "$(jq -r '
            def s(v): if v == null then "" else (v | tostring) end;
            if (.data | type) != "array" then empty
            else [ ([.data[].results[]?.amount // "0" | tonumber] | add // 0),
                   (if .has_more then "1" else "0" end),
                   s(.next_page) ] | @tsv
            end' <<< "$_resp" 2>/dev/null)"
        is_num "$_partial" || return 1
        _sum=$(awk "BEGIN{printf \"%.6f\", $_sum + $_partial}")
        _pages=$(( _pages + 1 ))
        { [ "$_has_more" = "1" ] && [ -n "$_page" ]; } || break
    done
    # The report states amounts as decimal strings in cents; the bar talks dollars.
    awk "BEGIN{printf \"%.4f\", $_sum / 100}"
}

# Total USD spent since epoch $1, priced from this machine's own Claude Code
# transcripts: the fallback for when the Admin API cost report is unreachable,
# which for an individual account is always — Anthropic does not issue Admin
# API keys without an organization. $2 is the projects directory holding the
# per-session JSONL files; $3 is an optional "pattern<TAB>in/out" list of
# per-MTok rate overrides, longest matching pattern winning, same matching rule
# as model_params.
#
# Necessarily an ESTIMATE, and labelled as one wherever it renders: it prices
# only the traffic this machine's Claude Code produced, so Console playground
# calls, other tools sharing the key, and other machines are invisible to it.
# It prices at list rates, which is what Claude Code's own Cost field does too.
local_spend_usd() {
    local _as_of="$1" _projects="$2" _rates="${3:-}"
    is_num "$_as_of" || return 1
    [ -d "$_projects" ] || return 1
    python3 - "$_as_of" "$_projects" "$_rates" 2>/dev/null <<'PY_LOCAL_SPEND'
import calendar
import json
import os
import sys

as_of = int(sys.argv[1])
projects = sys.argv[2]
overrides = sys.argv[3] if len(sys.argv) > 3 else ''

# USD per million tokens, (input, output), keyed by a lowercase substring of the
# model id; the longest match wins, so "opus-4-6" can differ from "opus". These
# are Anthropic list rates and they do change — model_pricing in config.json
# overrides any of them without anyone editing this table.
RATES = {
    'fable-5': (10.0, 50.0),
    'mythos-5': (10.0, 50.0),
    'opus-5': (5.0, 25.0),
    'opus-4-8': (5.0, 25.0),
    'opus-4-7': (5.0, 25.0),
    'opus-4-6': (5.0, 25.0),
    'sonnet-5': (2.0, 10.0),
    'sonnet-4-6': (3.0, 15.0),
    'haiku-4-5': (1.0, 5.0),
}
# Cache tokens are priced off the input rate: a 5-minute write costs 1.25x, a
# 1-hour write 2x, and a read 0.1x.
WRITE_5M, WRITE_1H, READ = 1.25, 2.0, 0.1

for line in overrides.splitlines():
    pattern, _, rate = line.strip().partition('\t')
    parts = rate.split('/')
    if pattern and len(parts) == 2:
        try:
            RATES[pattern.lower()] = (float(parts[0]), float(parts[1]))
        except ValueError:
            pass


def rate_for(model):
    model = (model or '').lower()
    best = None
    for pattern, rate in RATES.items():
        if pattern in model and (best is None or len(pattern) > len(best[0])):
            best = (pattern, rate)
    return best[1] if best else None


def to_epoch(stamp):
    # Transcript timestamps are UTC ISO-8601 ("2026-09-19T08:21:04.123Z"). Parsed
    # by hand rather than with datetime.fromisoformat, which rejects the trailing
    # Z before Python 3.11 and would there silently drop every line.
    try:
        date, _, clock = stamp.partition('T')
        year, month, day = (int(v) for v in date.split('-'))
        hour, minute, second = clock.rstrip('Z').split(':')[:3]
        return calendar.timegm((year, month, day, int(hour), int(minute),
                                int(float(second)), 0, 0, 0))
    except (ValueError, AttributeError):
        return None


# One assistant message reaches more than one transcript — resuming or forking
# a session copies its history into the new file, and in practice ~45% of rows
# in a day's transcripts are such copies. Billing happened once, so pricing
# every copy inflates the estimate by nearly half. Deduplicated on the API's own
# message id (requestId as the fallback); a row carrying neither is priced,
# since dropping it would under-count and it cannot be matched to anything.
seen_messages = set()

total = 0.0
for project in os.scandir(projects):
    if not project.is_dir():
        continue
    for entry in os.scandir(project.path):
        # A file untouched since the snapshot holds nothing inside the window.
        if not entry.name.endswith('.jsonl') or entry.stat().st_mtime < as_of:
            continue
        try:
            with open(entry.path, encoding='utf-8', errors='replace') as fh:
                for line in fh:
                    if '"assistant"' not in line:
                        continue
                    try:
                        row = json.loads(line)
                    except ValueError:
                        continue
                    if row.get('type') != 'assistant':
                        continue
                    stamp = to_epoch(row.get('timestamp'))
                    if stamp is None or stamp < as_of:
                        continue
                    message = row.get('message') or {}
                    identity = message.get('id') or row.get('requestId')
                    if identity:
                        if identity in seen_messages:
                            continue
                        seen_messages.add(identity)
                    usage = message.get('usage') or {}
                    rate = rate_for(message.get('model'))
                    if not rate:
                        continue
                    rate_in, rate_out = rate
                    creation = usage.get('cache_creation') or {}
                    write_5m = creation.get('ephemeral_5m_input_tokens')
                    write_1h = creation.get('ephemeral_1h_input_tokens')
                    if write_5m is None and write_1h is None:
                        # Older rows carry only the undifferentiated total; price
                        # it at the 5-minute rate, which is the default TTL.
                        write_5m = usage.get('cache_creation_input_tokens') or 0
                        write_1h = 0
                    tokens_in = (
                        (usage.get('input_tokens') or 0)
                        + (write_5m or 0) * WRITE_5M
                        + (write_1h or 0) * WRITE_1H
                        + (usage.get('cache_read_input_tokens') or 0) * READ
                    )
                    total += tokens_in * rate_in / 1e6
                    total += (usage.get('output_tokens') or 0) * rate_out / 1e6
        except OSError:
            continue

print('%.4f' % total)
PY_LOCAL_SPEND
}

# Timeout command, resolved once: GNU coreutils `timeout` on Linux, `gtimeout`
# from homebrew's coreutils on macOS. Neither present means git runs unbounded,
# exactly as it did before — a missing timeout must never disable git itself.
GIT_TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
    GIT_TIMEOUT_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
    GIT_TIMEOUT_CMD="gtimeout"
fi

# Every git call this script makes goes through here. The statusline re-runs
# every couple of seconds, so a git call that blocks — a stalled network mount,
# a credential helper waiting on a password — does not merely delay one render,
# it queues stuck processes behind every following one. The time limit turns a
# stuck call into the "no git here" case every caller already degrades to.
# GIT_TERMINAL_PROMPT and GCM_INTERACTIVE stop git from ever pausing to ask
# (none of these five commands touch the network, so nothing is lost);
# GIT_OPTIONAL_LOCKS keeps a read-only call from taking the index lock.
git_run() {
    # shellcheck disable=SC2086  # deliberate split: empty when no timeout exists
    GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=Never \
        ${GIT_TIMEOUT_CMD:+$GIT_TIMEOUT_CMD "$cfg_git_timeout"} git "$@" 2>/dev/null
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
CONFIG_MAX_BYTES=262144
config_warning_line=""

apply_preset() {
    local _v
    case "$1" in
        full)
            for _v in git_dirty git_ahead_behind git_file_stats activity agents todos orchestrator \
                      added_dirs prompt_cache today compactions speed; do
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
                      git_file_stats provider mode subscription cost total_tokens loc \
                      session_time thinking_time cache_ratio efficiency tool_calls \
                      activity agents todos orchestrator added_dirs prompt_cache \
                      today compactions speed; do
                printf -v "cfg_show_${_v}" '%s' 0
            done
            cfg_layout="compact"
            ;;
    esac
}

if [ -f "$CONFIG_FILE" ]; then
    if [ -L "$CONFIG_FILE" ] || [ "$(file_size "$CONFIG_FILE")" -gt "$CONFIG_MAX_BYTES" ]; then
        config_warning_line="${BOLD_RED}SUPER-STATUS CONFIG IS INVALID JSON - USING DEFAULTS: ${CONFIG_FILE}${RESET}"
    elif ! _cfg_out=$(jq -r '
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
            ["auto_compact_window", s(.auto_compact_window)],
            ["model_source", s(.model_source)],
            ["plan_label", s(.plan_label)],
            ["api_credit_balance", s(.api_credit_balance)],
            ["api_credit_as_of", s(.api_credit_as_of)],
            ["api_spend_cache_seconds", s(.api_spend_cache_seconds)],
            ["external_usage_path", s(.external_usage_path)],
            ["external_usage_max_age", s(.external_usage_max_age)],
            ["external_usage_write_path", s(.external_usage_write_path)],
            ["prompt_cache_ttl_seconds", s(.prompt_cache_ttl_seconds)],
            ["hyperlinks", s(.hyperlinks)],
            ["added_dirs_max", s(.added_dirs_max)],
            ["added_dirs_name_width", s(.added_dirs_name_width)],
            ["added_dirs_layout", s(.added_dirs_layout)],
            ["lines", (try (.lines | map(join(",")) | join("|")) catch "")],
            ["right_align", (.right_align | if type == "array" then join(",") elif type == "string" then . else "" end)],
            ["push_warning_threshold", s(.git.push_warning_threshold)],
            ["push_critical_threshold", s(.git.push_critical_threshold)],
            ["git_timeout_seconds", s(.git.timeout_seconds)],
            ["jj_enabled", s(.jj.enabled)]
          ]
          + ((.model_params // {}) | to_entries | map(["model_params_" + .key, s(.value)]))
          + ((.model_pricing // {}) | to_entries | map(["model_pricing_" + .key, s(.value)]))
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
                auto_compact_window) is_num "$_v" && [ "${_v%.*}" -ge 1000 ] && cfg_auto_compact_window="${_v%.*}" ;;
                model_source) case "$_v" in stdin|transcript|auto) cfg_model_source="$_v" ;; esac ;;
                plan_label) [ -n "$_v" ] && cfg_plan_label=$(trim_ws "$_v") ;;
                api_credit_balance) is_num "$_v" && cfg_api_credit_balance="$_v" ;;
                api_credit_as_of) [ -n "$_v" ] && cfg_api_credit_as_of=$(trim_ws "$_v") ;;
                api_spend_cache_seconds) is_num "$_v" && [ "${_v%.*}" -ge 60 ] && cfg_api_spend_cache_seconds="${_v%.*}" ;;
                external_usage_path) [ -n "$_v" ] && cfg_external_usage_path="$_v" ;;
                external_usage_max_age) is_num "$_v" && [ "${_v%.*}" -ge 0 ] && cfg_external_usage_max_age="${_v%.*}" ;;
                external_usage_write_path) [ -n "$_v" ] && cfg_external_usage_write_path="$_v" ;;
                prompt_cache_ttl_seconds) is_num "$_v" && [ "${_v%.*}" -ge 60 ] && cfg_prompt_cache_ttl_seconds="${_v%.*}" ;;
                hyperlinks) _b=$(to_bool "$_v") && cfg_hyperlinks="$_b" ;;
                added_dirs_max) is_num "$_v" && [ "${_v%.*}" -ge 1 ] && [ "${_v%.*}" -le 20 ] && cfg_added_dirs_max="${_v%.*}" ;;
                added_dirs_name_width) is_num "$_v" && [ "${_v%.*}" -ge 4 ] && [ "${_v%.*}" -le 80 ] && cfg_added_dirs_name_width="${_v%.*}" ;;
                added_dirs_layout) case "$_v" in inline|line) cfg_added_dirs_layout="$_v" ;; esac ;;
                right_align) [ -n "$_v" ] && cfg_right_align="$_v" ;;
                git_timeout_seconds) is_num "$_v" && [ "${_v%.*}" -ge 1 ] && [ "${_v%.*}" -le 60 ] && cfg_git_timeout="${_v%.*}" ;;
                jj_enabled) _b=$(to_bool "$_v") && cfg_jj_enabled="$_b" ;;
                model_params_*)
                    _p="${_k#model_params_}"
                    if [ -n "$_p" ] && [ -n "$_v" ]; then
                        cfg_model_params_patterns+=("$_p")
                        cfg_model_params_labels+=("$_v")
                    fi
                    ;;
                model_pricing_*)
                    _p="${_k#model_pricing_}"
                    if [ -n "$_p" ] && [ -n "$_v" ]; then
                        cfg_model_pricing_patterns+=("$_p")
                        cfg_model_pricing_labels+=("$_v")
                    fi
                    ;;
                lines) [ -n "$_v" ] && cfg_lines="$_v" ;;
                push_warning_threshold) is_num "$_v" && cfg_push_warning="${_v%.*}" ;;
                push_critical_threshold) is_num "$_v" && cfg_push_critical="${_v%.*}" ;;
                display_*)
                    _b=$(to_bool "$_v") || continue
                    case "${_k#display_}" in
                        model|mode|repo|branch|worktree|lines_changed|version|git_dirty|git_ahead_behind|git_file_stats|provider|effort|subscription|sessions|balance|context|cost|total_tokens|loc|session_time|thinking_time|cache_ratio|efficiency|tool_calls|activity|agents|todos|orchestrator|added_dirs|prompt_cache|today|compactions|speed)
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
C_MUTED="$GREY"; C_ACCENT="$ORANGE"; C_BAR_FILLED=""; C_BAR_EMPTY=""
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
        L_MODE_API="API"
        L_MODE_SUB="Sub"
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
        L_ADDED_DIRS="Added dirs:"
        L_PROMPT_CACHE="⏱ until"
        L_PROMPT_CACHE_EXPIRED="⏱ expired"
        L_TODAY="Today"
        L_COMPACTIONS="Compactions:"
        L_SPEED="out:"
        L_TOKENS_PER_SECOND="tok/s"
        L_ACTIVITY="Activity:"
        L_AGENTS="Agents:"
        L_TODO="Todo:"
        L_ORCA="Orca:"
        L_MASTER="Master:"
        L_RESET="Reset"
        L_LEFT="left"
        L_SUB_MISSING='SUBSCRIPTION START DATE IS MISSING - ADD IT TO THE CLAUDE.MD: "subscription_start_date": "dd/MM/yyyy"'
        L_SUB_INVALID='SUBSCRIPTION START DATE IS INVALID - ADD IT TO THE CLAUDE.MD: "subscription_start_date": "dd/MM/yyyy"'
        L_BAL_AS_OF="as of"
        L_BAL_ESTIMATE="est."
        L_BAL_DECLARED="declared"
        L_BAL_INVALID='API CREDIT SNAPSHOT DATE IS MISSING OR INVALID - ADD IT TO CONFIG.JSON: "api_credit_as_of": "dd/MM/yyyy [HH:MM]"'
        ;;
esac

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Single-pass stdin parse — one jq call emits every needed field as
# key<TAB>value (replacing ~25 per-field jq spawns). Supports both
# Claude Code and Google Antigravity CLI (agy).
# ---------------------------------------------------------------------------
model=""; effort_level=""; project_dir=""; cwd=""; current_dir=""; worktree=""
session_id=""; transcript_path=""; cc_version=""
agent_name=""; subagents_count=""
sv_used_pct=""; sv_remaining_pct=""; sv_window_size=""
sv_cur_in=""; sv_cur_cc=""; sv_cur_cr=""
api_ms=""; dur_ms=""; cost_usd=""; lines_added=""; lines_removed=""
five_util_probe=""; five_reset=""; seven_util_probe=""; seven_reset=""
is_agy_marker=""
added_dirs=()

while IFS=$'	' read -r _k _v; do
    case "$_k" in
        model) model="$_v" ;;
        effort_level) effort_level="$_v" ;;
        project_dir) project_dir="$_v" ;;
        cwd) cwd="$_v" ;;
        current_dir) current_dir="$_v" ;;
        worktree) worktree="$_v" ;;
        session_id) session_id="$_v" ;;
        transcript_path) transcript_path="$_v" ;;
        version) cc_version="$_v" ;;
        agent) agent_name="$_v" ;;
        subagents_count) subagents_count="$_v" ;;
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
        is_agy) is_agy_marker="$_v" ;;
        added_dir) [ -n "$_v" ] && added_dirs+=("$_v") ;;
    esac
done <<< "$(jq -r '
    def s(v): if v == null then "" else (v | tostring) end;
    ([
      ["model", s(.model.display_name // .model.name // .model.id // .model)],
      ["effort_level", s(.effort.level)],
      ["project_dir", s(.workspace.project_dir // .workspace.current_dir // .workspace // .workspaceUris[0])],
      ["cwd", s(.cwd // .workspace.current_dir // .workspace // .workspaceUris[0])],
      ["current_dir", s(.workspace.current_dir // .workspace // .workspaceUris[0])],
      ["worktree", s(.workspace.git_worktree)],
      ["session_id", s(.session_id // .conversation_id)],
      ["transcript_path", s(.transcript_path)],
      ["version", s(.version)],
      ["agent", s(.agent // .agent_state // .agentMode)],
      ["subagents_count", s(if (.subagents | type) == "array" then (.subagents | length) else "" end)],
      ["used_pct", s(.context_window.used_percentage // .context.used_percentage)],
      ["remaining_pct", s(.context_window.remaining_percentage // .context.remaining_percentage)],
      ["window_size", s(.context_window.context_window_size // .context.context_window_size)],
      ["cur_in", s(.context_window.current_usage.input_tokens // .context.input_tokens // .context_window.input_tokens)],
      ["cur_cc", s(.context_window.current_usage.cache_creation_input_tokens)],
      ["cur_cr", s(.context_window.current_usage.cache_read_input_tokens // .context.cached_tokens)],
      ["api_ms", s(.cost.total_api_duration_ms)],
      ["dur_ms", s(.cost.total_duration_ms)],
      ["cost_usd", s(.cost.total_cost_usd)],
      ["cost_la", s(.cost.total_lines_added)],
      ["cost_lr", s(.cost.total_lines_removed)],
      ["five_pct", s(.rate_limits.five_hour.used_percentage)],
      ["five_reset", s(.rate_limits.five_hour.resets_at)],
      ["seven_pct", s(.rate_limits.seven_day.used_percentage)],
      ["seven_reset", s(.rate_limits.seven_day.resets_at)],
      ["is_agy", s(if .vcsName != null or .agent_state != null or (.model.id != null and (.model.id | test("gemini"; "i"))) then 1 else 0 end)]
    ]
    + ((.workspace.added_dirs // .workspace.additional_directories // [])
       | if type == "array" then map(["added_dir", s(.)]) else [] end)
    ) | .[] | @tsv' <<< "$input" 2>/dev/null)"

# Every value above came from outside this script and every one of them is
# printed to a terminal, so all of them are cleaned in one place rather than at
# each render site — a new segment then cannot reintroduce the hole by
# forgetting. Paths keep their own cleaning at the point they are shortened.
model=$(sanitize_text "$model")
effort_level=$(sanitize_text "$effort_level")
worktree=$(sanitize_text "$worktree")
agent_name=$(sanitize_text "$agent_name")
cc_version=$(sanitize_text "$cc_version")

# Platform detection: Claude Code vs. Google Antigravity CLI (agy)
IS_ANTIGRAVITY=0
if [ "$is_agy_marker" = "1" ] || [ -n "$agent_name" ] || [ -n "$subagents_count" ]; then
    IS_ANTIGRAVITY=1
elif [ -n "$ANTIGRAVITY_AGENT" ] && [ -z "$five_util_probe" ] && [[ ! "$model" =~ [Cc]laude ]]; then
    IS_ANTIGRAVITY=1
fi

if [ -z "$transcript_path" ] && [ "$IS_ANTIGRAVITY" -eq 1 ] && [ -n "$session_id" ]; then
    _agy_transcript="$HOME/.gemini/antigravity-cli/brain/${session_id}/.system_generated/logs/transcript.jsonl"
    [ -f "$_agy_transcript" ] && transcript_path="$_agy_transcript"
fi

# Rate-limit persistence across sessions.
# Claude Code only populates `rate_limits` in the stdin JSON once the session
# has made a real API call; a fresh session (right after /clear, or before its
# first turn) omits it, which would blank the Sessions 5h/Nd bars until a task
# starts. Those windows are account-global, not per-session, so the last-seen
# values are cached to disk and restored on a miss — but only while the cached
# reset timestamp is still in the future, so a window that has since rolled over
# is never resurrected as a stale percentage. The 5h and 7d windows reset
# independently, so each is restored on its own.
# ---------------------------------------------------------------------------
_rl_cache="$CACHE_ROOT/rate-limits.tsv"
RL_FROM_STDIN=0
if is_num "$five_util_probe" && is_num "$seven_util_probe"; then
    RL_FROM_STDIN=1
    debug_log "rate limits: from stdin (5h=${five_util_probe}% 7d=${seven_util_probe}%)"
    printf '%s\t%s\t%s\t%s\n' \
        "$five_util_probe" "$five_reset" "$seven_util_probe" "$seven_reset" \
        > "$_rl_cache" 2>/dev/null
elif [ -f "$_rl_cache" ]; then
    debug_log "rate limits: absent from stdin, trying the cross-session cache"
    IFS=$'\t' read -r _rl_five_pct _rl_five_reset _rl_seven_pct _rl_seven_reset \
        < "$_rl_cache" 2>/dev/null
    _rl_now=$(date +%s)
    if [ -z "$five_util_probe" ] && is_num "$_rl_five_pct" \
        && is_num "${_rl_five_reset%.*}" && [ "${_rl_five_reset%.*}" -gt "$_rl_now" ]; then
        five_util_probe="$_rl_five_pct"; five_reset="$_rl_five_reset"
    fi
    if [ -z "$seven_util_probe" ] && is_num "$_rl_seven_pct" \
        && is_num "${_rl_seven_reset%.*}" && [ "${_rl_seven_reset%.*}" -gt "$_rl_now" ]; then
        seven_util_probe="$_rl_seven_pct"; seven_reset="$_rl_seven_reset"
    fi
else
    debug_log "rate limits: absent from stdin and no cache yet (the 5h/Nd bars stay empty until this session's first API call)"
fi

# External usage snapshot (opt-in): when stdin omits rate_limits and no live
# cache filled them, a JSON file maintained by another tool (e.g. a zero-token
# scheduled `get_usage` job) can seed the 5h/Nd bars from session start, and
# optionally carry per-model weekly windows the stdin payload never includes.
# Only a snapshot fresher than external_usage_max_age is trusted, so a stale
# file never resurrects a rolled-over window.
# Producer side (opt-in): the authoritative rate-limit windows arrive free on
# stdin, are rendered, and were then thrown away — while usage-feeder.sh has to
# ask a throttled source for the same numbers. Writing them out means the feeder
# usually finds recent data already waiting and has to poll less, not more.
#
# This makes the statusline a SECOND writer on a file the feeder maintains, so
# it takes the feeder's own rule: never replace fresher data with older. A
# window that has rolled over has a later resets_at; within the same window a
# higher used_percentage is the newer reading. Anything else is left alone, so
# the bars can only ever move forward. The write is staged through .tmp and
# promoted by mv, so a render interrupted mid-write cannot leave a truncated
# snapshot for the feeder or the consumer side below to read.
if [ "$RL_FROM_STDIN" -eq 1 ] && [ -n "$cfg_external_usage_write_path" ]; then
    _euw_path="$cfg_external_usage_write_path"
    # shellcheck disable=SC2088  # matching a literal leading ~/ in config text, not expanding
    case "$_euw_path" in "~/"*) _euw_path="$HOME/${_euw_path#\~/}" ;; esac
    _euw_ok=0
    case "$_euw_path" in
        /*.json) [ -d "${_euw_path%/*}" ] && _euw_ok=1 ;;
    esac
    if [ "$_euw_ok" -eq 1 ]; then
        _euw_prev_reset=0; _euw_prev_pct=-1
        if [ -f "$_euw_path" ]; then
            IFS=$'\t' read -r _euw_prev_reset _euw_prev_pct <<< "$(jq -r '
                [(.rate_limits.five_hour.resets_at // 0), (.rate_limits.five_hour.used_percentage // -1)]
                | @tsv' "$_euw_path" 2>/dev/null)"
            is_num "${_euw_prev_reset%.*}" || _euw_prev_reset=0
            is_num "${_euw_prev_pct%.*}" || _euw_prev_pct=-1
        fi
        _euw_write=0
        if [ "${five_reset%.*}" -gt "${_euw_prev_reset%.*}" ] 2>/dev/null; then
            _euw_write=1
        elif [ "${five_reset%.*}" = "${_euw_prev_reset%.*}" ] \
             && [ "${five_util_probe%.*}" -ge "${_euw_prev_pct%.*}" ] 2>/dev/null; then
            _euw_write=1
        fi
        if [ "$_euw_write" -eq 1 ]; then
            if jq -n --argjson f5 "$five_util_probe" --argjson r5 "${five_reset:-0}" \
                    --argjson f7 "$seven_util_probe" --argjson r7 "${seven_reset:-0}" \
                    '{rate_limits: {five_hour: {used_percentage: $f5, resets_at: $r5},
                                    seven_day: {used_percentage: $f7, resets_at: $r7}}}' \
                    > "${_euw_path}.tmp" 2>/dev/null; then
                chmod 600 "${_euw_path}.tmp" 2>/dev/null
                mv "${_euw_path}.tmp" "$_euw_path" 2>/dev/null
            else
                rm -f "${_euw_path}.tmp" 2>/dev/null
            fi
        fi
    fi
fi

model_scoped_rows=""
if [ -n "$cfg_external_usage_path" ]; then
    _eu_path="$cfg_external_usage_path"
    # shellcheck disable=SC2088  # matching a literal leading ~/ in config text, not expanding
    case "$_eu_path" in "~/"*) _eu_path="$HOME/${_eu_path#\~/}" ;; esac
    if [ -f "$_eu_path" ]; then
        _eu_age=$(( $(date +%s) - $(file_mtime "$_eu_path") ))
        if [ "$cfg_external_usage_max_age" -ne 0 ] && [ "$_eu_age" -gt "$cfg_external_usage_max_age" ]; then
            debug_log "external usage snapshot ignored: ${_eu_age}s old, cap is ${cfg_external_usage_max_age}s"
        fi
        if [ "$cfg_external_usage_max_age" -eq 0 ] || [ "$_eu_age" -le "$cfg_external_usage_max_age" ]; then
            _eu_out=$(jq -r '
                def s(v): if v == null then "" else (v | tostring) end;
                (
                  [
                    ["WINDOW", "five", s(.rate_limits.five_hour.used_percentage), s(.rate_limits.five_hour.resets_at)],
                    ["WINDOW", "seven", s(.rate_limits.seven_day.used_percentage), s(.rate_limits.seven_day.resets_at)]
                  ]
                  + (((.model_scoped // {}) | to_entries) | map(["MODEL", .key, s(.value.used_percentage), s(.value.resets_at)]))
                ) | .[] | @tsv' "$_eu_path" 2>/dev/null)
            while IFS=$'\t' read -r _eu_tag _eu_a _eu_b _eu_c; do
                case "$_eu_tag" in
                    WINDOW)
                        if [ "$_eu_a" = "five" ] && [ -z "$five_util_probe" ] && is_num "$_eu_b"; then
                            five_util_probe="$_eu_b"; five_reset="$_eu_c"
                        elif [ "$_eu_a" = "seven" ] && [ -z "$seven_util_probe" ] && is_num "$_eu_b"; then
                            seven_util_probe="$_eu_b"; seven_reset="$_eu_c"
                        fi
                        ;;
                    MODEL)
                        is_num "$_eu_b" && model_scoped_rows+="${_eu_a}"$'\t'"${_eu_b}"$'\t'"${_eu_c}"$'\n'
                        ;;
                esac
            done <<< "$_eu_out"
        fi
    fi
fi

[ "$worktree" = "null" ] && worktree=""
[ -z "$cwd" ] && cwd="$current_dir"

git_root=$(git_run -C "${cwd:-$project_dir}" rev-parse --show-toplevel)
debug_log "git: timeout=${GIT_TIMEOUT_CMD:-none} root=${git_root:-<none>}"
[ -z "$git_root" ] && git_root="${cwd:-$project_dir}"
git_branch=""
[ -n "$git_root" ] && [ -d "$git_root" ] && \
    git_branch=$(git_run -C "$git_root" rev-parse --abbrev-ref HEAD)

# ---------------------------------------------------------------------------
# Jujutsu — opt-in, and one version control system per repository, never both
# on the line at once. Two conditions are required before jj takes over: the
# jj.enabled flag, and a real .jj control directory at or above the working
# directory. A stray .jj inside an ordinary git repository must not cost that
# repository its branch name, which is the one way this could go wrong on
# line 1 of every session.
#
# --ignore-working-copy is not optional: without it every jj command snapshots
# the working copy, so a statusline re-running every two seconds would be
# writing to the user's repository continuously. This segment is read-only.
# ---------------------------------------------------------------------------
JJ_ROOT=""
jj_conflict=""
git_dirty_override=""
if [ "$cfg_jj_enabled" = "1" ] && command -v jj >/dev/null 2>&1; then
    _jj_probe="${cwd:-$project_dir}"
    while [ -n "$_jj_probe" ] && [ "$_jj_probe" != "/" ]; do
        if [ -d "$_jj_probe/.jj" ]; then
            JJ_ROOT="$_jj_probe"
            break
        fi
        _jj_probe="${_jj_probe%/*}"
    done
fi
if [ -n "$JJ_ROOT" ]; then
    git_root="$JJ_ROOT"
    _jj_dir="$CACHE_ROOT/jj-cache"
    mkdir -p "$_jj_dir"
    _jj_key=$(echo "$JJ_ROOT" | tr '/' '_')
    _jj_file="$_jj_dir/${_jj_key}.txt"
    _jj_stamp="$_jj_dir/${_jj_key}.stamp"
    _jj_do=1
    if [ -f "$_jj_stamp" ]; then
        [ $(( $(date +%s) - $(file_mtime "$_jj_stamp") )) -lt 10 ] && _jj_do=0
    fi
    if [ "$_jj_do" -eq 1 ]; then
        # shellcheck disable=SC2086  # deliberate split: empty when no timeout exists
        ${GIT_TIMEOUT_CMD:+$GIT_TIMEOUT_CMD "$cfg_git_timeout"} \
            jj --repository "$JJ_ROOT" --no-pager --color never --ignore-working-copy \
               log --no-graph -r @ -T \
               'separate("\t", bookmarks.join(","), change_id.shortest(8), if(empty, "", "dirty"), if(conflict, "conflict", "")) ++ "\n"' \
            > "$_jj_file" 2>/dev/null
        touch "$_jj_stamp"
    fi
    IFS=$'\t' read -r _jj_bookmarks _jj_change _jj_dirty _jj_conf < "$_jj_file" 2>/dev/null
    git_branch=$(sanitize_text "${_jj_bookmarks:-$_jj_change}")
    [ "$_jj_dirty" = "dirty" ] && git_dirty_override=1
    [ "$_jj_conf" = "conflict" ] && jj_conflict=1
fi

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

# Bedrock / Vertex are selected by their own env flags (or a matching base URL),
# not by ANTHROPIC_BASE_URL naming, so they're detected separately.
IS_BEDROCK=0
IS_VERTEX=0
case "${CLAUDE_CODE_USE_BEDROCK:-}" in 1|true) IS_BEDROCK=1 ;; esac
case "${CLAUDE_CODE_USE_VERTEX:-}" in 1|true) IS_VERTEX=1 ;; esac
case "$ANTHROPIC_BASE_URL" in
    *bedrock*|*amazonaws.com*) IS_BEDROCK=1 ;;
    *aiplatform.googleapis.com*|*-vertex*) IS_VERTEX=1 ;;
esac

# A non-first-party backend is anything but a bare/first-party Anthropic setup.
IS_PROXY=0
[ "$IS_OPENROUTER" -eq 1 ] && IS_PROXY=1
[ "$IS_BEDROCK" -eq 1 ] && IS_PROXY=1
[ "$IS_VERTEX" -eq 1 ] && IS_PROXY=1
case "$ANTHROPIC_BASE_URL" in
    ""|*api.anthropic.com*) ;;
    *) IS_PROXY=1 ;;
esac

IS_SUBSCRIPTION=0
is_num "$five_util_probe" && is_num "$seven_util_probe" && IS_SUBSCRIPTION=1

# ---------------------------------------------------------------------------
# Account mode — how this account pays: "API" (prepaid/invoice credit billing)
# or a named subscription tier. ~/.claude.json's oauthAccount is the only local
# record of it; its seatTier names the tier on accounts where Anthropic
# populates it, which it does not for most subscribers, so a config-declared
# plan_label outranks everything. Behind a proxy none of this describes who is
# actually billed, so the [provider] badge speaks for the backend instead.
# ---------------------------------------------------------------------------
ACCOUNT_MODE=""
ACCOUNT_MODE_KIND=""

resolve_account_mode() {
    local _billing="" _seat=""
    if [ -f "$HOME/.claude.json" ]; then
        IFS=$'\t' read -r _billing _seat <<< "$(jq -r '
            def s(v): if v == null then "" else (v | tostring) end;
            [s(.oauthAccount.billingType), s(.oauthAccount.seatTier)] | @tsv' \
            "$HOME/.claude.json" 2>/dev/null)"
    fi
    case "$_billing" in
        prepaid|invoice) ACCOUNT_MODE_KIND="api" ;;
        subscription)    ACCOUNT_MODE_KIND="subscription" ;;
    esac
    # stdin's rate_limits only ever accompany a subscription, so they settle the
    # kind when ~/.claude.json is missing (fresh machine, or a sandboxed HOME).
    [ -z "$ACCOUNT_MODE_KIND" ] && [ "$IS_SUBSCRIPTION" -eq 1 ] && ACCOUNT_MODE_KIND="subscription"

    if [ -n "$cfg_plan_label" ]; then
        ACCOUNT_MODE="$cfg_plan_label"
    elif [ -n "$_seat" ]; then
        ACCOUNT_MODE=$(seat_tier_label "$_seat")
    elif [ "$ACCOUNT_MODE_KIND" = "api" ]; then
        ACCOUNT_MODE="$L_MODE_API"
    elif [ "$ACCOUNT_MODE_KIND" = "subscription" ]; then
        ACCOUNT_MODE="$L_MODE_SUB"
    fi
}
resolve_account_mode

mode_badge=""
if [ "$cfg_show_mode" = "1" ] && [ "$IS_ANTIGRAVITY" -eq 0 ]; then
    if [ -n "$cfg_plan_label" ] || [ "$IS_PROXY" -eq 0 ]; then
        mode_badge="$ACCOUNT_MODE"
    fi
fi

# Provider badge on the model segment — first-party Anthropic shows nothing;
# any other backend is named explicitly so the backend mode is visible at a glance.
provider_badge=""
if [ "$cfg_show_provider" = "1" ]; then
    if [ "$IS_OPENROUTER" -eq 1 ]; then
        provider_badge="OpenRouter"
    elif [ "$IS_BEDROCK" -eq 1 ]; then
        provider_badge="Bedrock"
    elif [ "$IS_VERTEX" -eq 1 ]; then
        provider_badge="Vertex"
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

# model_source: optionally recover the real model name from the transcript when a
# proxy may be rewriting the stdin display_name (auto = only behind a proxy).
_want_transcript_model=0
case "$cfg_model_source" in
    transcript) _want_transcript_model=1 ;;
    auto) [ "$IS_PROXY" -eq 1 ] && _want_transcript_model=1 ;;
esac

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
# jj already answered the dirty question in its own pass, and has no upstream
# ahead/behind or staging area to report — so git is not consulted at all for a
# repository jj has taken over.
if [ -n "$JJ_ROOT" ]; then
    git_dirty="${git_dirty_override:-}"
elif [ -n "$git_branch" ] && { [ "$cfg_show_git_dirty" = "1" ] || [ "$cfg_show_git_ahead_behind" = "1" ] || [ "$cfg_show_git_file_stats" = "1" ]; }; then
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
            done < <(git_run -C "$git_root" status --porcelain)
        else
            # First line only — a dirty/clean answer doesn't need the full listing.
            _first=$(git_run -C "$git_root" status --porcelain | head -n 1)
            [ -n "$_first" ] && _d=1
        fi
        if [ "$cfg_show_git_ahead_behind" = "1" ]; then
            read -r _bh _ah <<< "$(git_run -C "$git_root" rev-list --left-right --count '@{upstream}...HEAD')"
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
                master_open_status=$(sanitize_text "$_ms_status")
                if [[ "$_ms_title" == *"spawned="* ]]; then
                    _ms_sp="${_ms_title#*spawned=}"
                    master_open_spawned=$(trim_ws "${_ms_sp%%]*}")
                fi
                if [[ "$_ms_title" == *"["* ]]; then
                    master_open_title=$(sanitize_text "${_ms_title%%\[*}")
                else
                    master_open_title=$(sanitize_text "$_ms_title")
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
# When an auto-compact window is configured, re-base the whole context readout
# (percent, used/max, remaining) onto it so the figure matches `/context`, which
# measures against the auto-compact threshold rather than the full model window.
if [ "$cfg_auto_compact_window" -gt 0 ]; then
    window_size="$cfg_auto_compact_window"
    pct=$(( token_total * 100 / window_size ))
    sv_remaining_pct=""
elif ! is_num "$pct"; then
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
transcript_model=""
tool_calls_total=""
bucket_skills=""; bucket_code=""; bucket_commands=""
bucket_read=""; bucket_mcp=""; bucket_other=""
activity_value=""
agents_value=""
todo_value=""
compactions_count=""
prompt_cache_expiry=""; prompt_cache_ttl=""; prompt_cache_fallback_base=""
speed_value=""

_need_transcript=0
for _flag in "$cfg_show_total_tokens" "$cfg_show_tool_calls" "$cfg_show_efficiency" \
             "$cfg_show_activity" "$cfg_show_agents" "$cfg_show_todos" \
             "$cfg_show_compactions" "$cfg_show_prompt_cache" "$cfg_show_speed"; do
    [ "$_flag" = "1" ] && _need_transcript=1
done
[ "$_want_transcript_model" -eq 1 ] && _need_transcript=1

if [ "$_need_transcript" -eq 1 ] && [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    _tr_dir="$CACHE_ROOT/transcript-cache"
    mkdir -p "$_tr_dir"
    _tr_key="${session_id:-$(echo "$transcript_path" | tr '/' '_')}"
    _tr_file="$_tr_dir/${_tr_key}.txt"
    _tr_stamp="$_tr_dir/${_tr_key}.mtime"
    _tr_src_mtime=$(file_mtime "$transcript_path")
    _tr_cached_mtime=$(cat "$_tr_stamp" 2>/dev/null || echo -1)
    if [ "$_tr_src_mtime" != "$_tr_cached_mtime" ]; then
        debug_log "transcript changed (mtime ${_tr_src_mtime}); re-running the transcript pass"
        _tr_value=$(python3 - "$transcript_path" 2>/dev/null <<'PYEOF'
import json
import os
import re
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
latest_model = ''
compactions = 0
# Prompt-cache expiry and output speed are both read off the newest MAIN-session
# assistant message. Sub-agent responses (isSidechain) are excluded on purpose:
# they run against their own cache and never refresh this session's, so counting
# one would report an expiry that is not the one the next message pays for.
cache_write_epoch = None
cache_write_ttl = 0
last_main_assistant_epoch = None
speed_tokens = 0
speed_seconds = None
previous_epoch = None


# A transcript records whatever the session touched — a file name, a search
# pattern, a to-do title, an agent description — and every one of those reaches
# a terminal that obeys escape sequences. Whole sequences are deleted first, so
# the truncation below can never leave a half-removed sequence behind; what is
# left of the control characters (and the bidi overrides, which disguise what a
# line really says) becomes a space, preserving the old tab/newline behaviour.
_ESC_RE = re.compile(r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?|\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[@-_]?')
_CTRL_RE = re.compile('[\x00-\x1f\x7f-\x9f‎‏‪-‮⁦-⁩]')


def clean(text, limit):
    if not isinstance(text, str):
        return ''
    return _CTRL_RE.sub(' ', _ESC_RE.sub('', text)).strip()[:limit]


def to_seconds(timestamp):
    if not isinstance(timestamp, str):
        return None
    try:
        return datetime.fromisoformat(timestamp.replace('Z', '+00:00')).timestamp()
    except Exception:
        return None


def to_epoch(timestamp):
    seconds = to_seconds(timestamp)
    return '' if seconds is None else str(int(seconds))


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


# Absolute file path of a tool call, for the optional activity hyperlink. Only
# an already-absolute path qualifies: a relative one would have to be resolved
# against a working directory this pass does not know, and guessing it would
# produce a link that opens the wrong file.
def path_for(tool_input):
    if not isinstance(tool_input, dict):
        return ''
    candidate = tool_input.get('file_path') or tool_input.get('path') or tool_input.get('notebook_path')
    if isinstance(candidate, str) and candidate.startswith('/'):
        return clean(candidate, 200)
    return ''


def is_async_launch(block):
    if block.get('isAsync') is True or block.get('status') == 'async_launched':
        return True
    inner = block.get('content')
    items = inner if isinstance(inner, list) else [inner]
    for item in items:
        if isinstance(item, dict) and (item.get('isAsync') is True or item.get('status') == 'async_launched'):
            return True
    return False


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
            if obj.get('type') == 'system' and obj.get('subtype') == 'compact_boundary':
                compactions += 1
            row_epoch = to_seconds(obj.get('timestamp'))
            msg = obj.get('message') or {}
            role = msg.get('role')
            content = msg.get('content')
            if role == 'assistant':
                model_name = msg.get('model')
                if isinstance(model_name, str) and model_name and model_name != '<synthetic>':
                    latest_model = clean(model_name, 60)
                usage = msg.get('usage') or {}
                for key in ('input_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens'):
                    value = usage.get(key)
                    if isinstance(value, (int, float)):
                        total_in += value
                out = usage.get('output_tokens')
                if isinstance(out, (int, float)):
                    total_out += out
                if not obj.get('isSidechain') and row_epoch is not None:
                    last_main_assistant_epoch = row_epoch
                    creation = usage.get('cache_creation') or {}
                    ttl = 0
                    if creation.get('ephemeral_1h_input_tokens'):
                        ttl = 3600
                    elif creation.get('ephemeral_5m_input_tokens'):
                        ttl = 300
                    elif usage.get('cache_creation_input_tokens'):
                        ttl = 300
                    if ttl:
                        cache_write_epoch = row_epoch
                        cache_write_ttl = ttl
                    # The interval is measured to the row that triggered this
                    # response (a user message or a tool result), which is the
                    # only timing the transcript records. It is meaningless
                    # across a resume or a long idle gap, so the render side
                    # drops any figure outside a plausible band.
                    if isinstance(out, (int, float)) and previous_epoch is not None:
                        speed_tokens = out
                        speed_seconds = row_epoch - previous_epoch
            if row_epoch is not None:
                previous_epoch = row_epoch
            elif obj.get('type') == 'PLANNER_RESPONSE':
                usage = obj.get('usage') or {}
                for key in ('input_tokens', 'prompt_tokens', 'cached_tokens', 'cache_read_input_tokens'):
                    value = usage.get(key)
                    if isinstance(value, (int, float)):
                        total_in += value
                for key in ('output_tokens', 'completion_tokens'):
                    value = usage.get(key)
                    if isinstance(value, (int, float)):
                        total_out += value
                model_name = obj.get('model') or (obj.get('model_info') or {}).get('name')
                if isinstance(model_name, str) and model_name:
                    latest_model = clean(model_name, 60)
                tool_calls = obj.get('tool_calls')
                if isinstance(tool_calls, list):
                    for tc in tool_calls:
                        if not isinstance(tc, dict): continue
                        name = tc.get('name') or ''
                        low = name.lower()
                        if name.startswith('mcp_') or name == 'call_mcp_tool':
                            buckets['MCP'] += 1
                        elif 'skill' in low or name == 'invoke_subagent':
                            buckets['SKILLS'] += 1
                        elif low in code_tools or low in {'write_to_file', 'replace_file_content'}:
                            buckets['CODE'] += 1
                        elif low in {'run_command', 'bash'}:
                            buckets['COMMANDS'] += 1
                        elif low in read_tools or low in {'view_file', 'grep_search', 'find_by_name', 'list_dir', 'read_url_content'}:
                            buckets['READ'] += 1
                        else:
                            buckets['OTHER'] += 1
                        entry = {
                            'id': tc.get('id') or str(len(tools)),
                            'name': clean(name, 24),
                            'low': low,
                            'done': True,
                            'epoch': to_epoch(obj.get('created_at')),
                            'target': clean(target_for(name, tc.get('arguments') or {}), 30),
                            'path': path_for(tc.get('arguments') or {}),
                        }
                        tools.append(entry)
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
                        'name': clean(name, 24),
                        'low': low,
                        'done': False,
                        'epoch': to_epoch(obj.get('timestamp')),
                        'target': clean(target_for(name, tool_input), 30),
                        'path': path_for(tool_input),
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
                        tools_by_id[tool_id]['done'] = not is_async_launch(block)
except Exception:
    pass

print(f'TOKENS\t{int(total_in)}\t{int(total_out)}')
if latest_model:
    print(f'MODEL\t{latest_model}')
print(f'BUCKET\tTOTAL\t{sum(buckets.values())}')
for key, count in buckets.items():
    print(f'BUCKET\t{key}\t{count}')
if compactions:
    print(f'COMPACTIONS\t{compactions}')
if cache_write_epoch is not None and cache_write_ttl:
    print(f'CACHEEXP\t{int(cache_write_epoch + cache_write_ttl)}\t{cache_write_ttl}')
elif last_main_assistant_epoch is not None:
    # No tier recorded on any cache write — the render side dates the
    # configured fallback TTL from here rather than assuming a tier.
    print(f'CACHEBASE\t{int(last_main_assistant_epoch)}')
# A rate is only meaningful over a plausible interval: below half a second the
# division amplifies clock noise, and a gap of minutes means the session was
# idle, not slow. Outside that band, and under a response too short to average,
# nothing is emitted rather than a figure that would mislead.
if speed_seconds is not None and 0.5 <= speed_seconds <= 600 and speed_tokens >= 50:
    print('SPEED\t%.1f' % (speed_tokens / speed_seconds))

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
    groups.append({'name': entry['name'], 'status': status, 'count': 1,
                   'target': entry['target'], 'path': entry.get('path', '')})
for group in groups:
    target = group['target'] if group['count'] == 1 else ''
    path = group['path'] if group['count'] == 1 else ''
    print(f"ACT\t{group['status']}\t{group['count']}\t{group['name']}\t{target}\t{path}")

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
        while IFS=$'\t' read -r _tag _a _b _c _d _e; do
            case "$_tag" in
                TOKENS)
                    session_total_input="$_a"; session_total_output="$_b" ;;
                MODEL)
                    transcript_model="$_a" ;;
                COMPACTIONS)
                    is_num "$_a" && compactions_count="$_a" ;;
                CACHEEXP)
                    is_num "$_a" && { prompt_cache_expiry="$_a"; prompt_cache_ttl="$_b"; } ;;
                CACHEBASE)
                    is_num "$_a" && prompt_cache_fallback_base="$_a" ;;
                SPEED)
                    is_num "$_a" && speed_value="$_a" ;;
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
                    # _a status, _b count, _c name, _d target, _e absolute path
                    _act_target="$_d"
                    if [ "$cfg_hyperlinks" = "1" ] && [ -n "$_d" ] && [ -n "$_e" ]; then
                        _act_link=$(safe_hyperlink "$_e" "$_d") && _act_target="$_act_link"
                    fi
                    if [ "$_a" = "run" ]; then
                        _act="${ORANGE}◐${RESET} ${CYAN}${_c}${RESET}"
                        [ -n "$_d" ] && _act="${_act}${C_MUTED}: ${_act_target}${RESET}"
                    elif is_num "$_b" && [ "$_b" -gt 1 ]; then
                        _act="${GREEN}✓${RESET} ${CYAN}${_c}${RESET} ${C_ACCENT}×${_b}${RESET}"
                    else
                        _act="${GREEN}✓${RESET} ${CYAN}${_c}${RESET}"
                        [ -n "$_d" ] && _act="${_act}${C_MUTED}: ${_act_target}${RESET}"
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

# Override the displayed model name with the real one from the transcript when
# model_source asked for it and the transcript actually named a model. Raw ids
# (claude-sonnet-4-6-20250101) are humanized to "Claude Sonnet 4.6".
if [ "$_want_transcript_model" -eq 1 ] && [ -n "$transcript_model" ]; then
    model=$(humanize_model_id "$transcript_model")
elif [[ "$model" =~ ^(claude|gemini)- ]]; then
    model=$(humanize_model_id "$model")
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
            # Single cycle anchored to the declared start date: start_date ..
            # start_date + 1 calendar month. Deliberately does NOT roll forward
            # to a later cycle — renewal isn't automatic (no billing date in the
            # stdin JSON), so once the paid month elapses the bar stays pinned at
            # 100% ("renewal due") until /super-status:subscribe bumps the const,
            # rather than snapping back to 0% for a cycle that wasn't paid for.
            _cycle_start=$(add_months_epoch "$_sub_day" "$_sub_month" "$_sub_year" 0)
            _cycle_end=$(add_months_epoch "$_sub_day" "$_sub_month" "$_sub_year" 1)
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
                _sub_reset_marker=$(format_reset_marker "$_cycle_end")
                subscription_value="${_sub_bar} ${_sub_color}${_sub_pct}%${RESET} $(muted "${L_RESET} ${_sub_days_left}d${_sub_reset_marker:+ (${_sub_reset_marker})}")"
            fi
            ;;
    esac
fi

# ---------------------------------------------------------------------------
# Segments — every field renders into a named segment string (or stays empty,
# which drops it and its separator); the layout assembly at the bottom maps
# segments onto lines. Segment names are the config/layout vocabulary.
# ---------------------------------------------------------------------------

seg_mode=""
[ -n "$mode_badge" ] && seg_mode="${C_ACCENT}${mode_badge}${RESET}"

seg_model=""
if [ "$cfg_show_model" = "1" ] && [ -n "$model" ]; then
    seg_model="${C_MODEL}${L_MODEL}${RESET} ${C_MODEL}${model}${RESET}"
    _model_params=$(model_params_label "$model")
    [ -n "$_model_params" ] && seg_model="${seg_model} $(muted "(${_model_params})")"
    [ -n "$provider_badge" ] && seg_model="${seg_model} $(muted "[${provider_badge}]")"
    if [ "$cfg_show_effort" = "1" ] && [ -n "$effort_level" ]; then
        _effort_display="$(tr '[:lower:]' '[:upper:]' <<<"${effort_level:0:1}")${effort_level:1}"
        seg_model="${seg_model} $(muted "[${_effort_display}]")"
    fi
fi

# Branch decorations (dirty marker, ahead/behind, file stats) build once here;
# they attach to the branch wherever it ends up rendering (combined or alone).
_branch_part=""
if [ "$cfg_show_branch" = "1" ] && [ -n "$git_branch" ]; then
    _branch_display="$git_branch"
    [ "$cfg_show_git_dirty" = "1" ] && [ "$git_dirty" = "1" ] && _branch_display="${_branch_display}*"
    _branch_part="${C_BRANCH}${_branch_display}${RESET}"
    # An unresolved jj conflict is the one state worth a colour of its own here:
    # it blocks the next operation, which a dirty marker does not.
    [ "$jj_conflict" = "1" ] && _branch_part="${_branch_part} ${RED}⚠${RESET}"
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
    _repo_display=$(sanitize_text "$(path_tail "$project_dir" "$cfg_path_levels")")
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

seg_agent=""
if [ -n "$agent_name" ] && [ "$agent_name" != "null" ]; then
    seg_agent="${C_LABEL}Agent:${RESET} ${CYAN}${agent_name}${RESET}"
    if is_num "$subagents_count" && [ "$subagents_count" -gt 0 ]; then
        seg_agent="${seg_agent} $(muted "(+${subagents_count} subagent$([ "$subagents_count" -gt 1 ] && echo "s"))")"
    fi
fi

seg_version=""
if [ "$cfg_show_version" = "1" ] && [ -n "$cc_version" ]; then
    if [ "$IS_ANTIGRAVITY" -eq 1 ]; then
        seg_version="$(muted "agy v${cc_version}")"
    else
        seg_version="$(muted "v${cc_version}")"
    fi
fi

seg_subscription="$subscription_value"
[ -n "$seg_subscription" ] && seg_subscription="${C_LABEL}${L_SUBSCRIPTION}${RESET} ${seg_subscription}"

# Sessions: 5h / Nd usage (Nd = actual days remaining until the weekly window
# resets, computed live — not hardcoded to "7d", since it's a rolling window).
# Bars are colored to match their usage color (green/orange/red). Each reset
# is the relative countdown plus an absolute "when" marker in parens: the 5h
# window always shows a clock time (HH:MM) since it's always hours away; the
# weekly window shows HH:MM when it lands today, else a date (dd/MM).
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
    if [ -n "$five_reset_countdown" ]; then
        five_reset_marker=$(format_reset_marker "$five_reset" clock)
        seg_sessions="${seg_sessions} $(muted "${L_RESET} ${five_reset_countdown}${five_reset_marker:+ (${five_reset_marker})}")"
    fi

    seg_sessions="${seg_sessions} $(muted "|") ${C_LABEL}${seven_days_label}${RESET} ${seven_bar} ${seven_color}${seven_pct}%${RESET}"
    if [ -n "$seven_reset_countdown" ]; then
        seven_reset_marker=$(format_reset_marker "$seven_reset")
        seg_sessions="${seg_sessions} $(muted "${L_RESET} ${seven_reset_countdown}${seven_reset_marker:+ (${seven_reset_marker})}")"
    fi

    # Per-model weekly windows from the external snapshot (e.g. a Fable quota the
    # stdin payload never carries): one compact "name bar pct%" clause each.
    if [ -n "$model_scoped_rows" ]; then
        while IFS=$'\t' read -r _ms_name _ms_pct _ms_reset; do
            _ms_name=$(sanitize_text "$_ms_name")
            [ -n "$_ms_name" ] || continue
            _ms_pct=${_ms_pct%.*}; is_num "$_ms_pct" || continue
            _ms_color=$(usage_color "$_ms_pct" "$cfg_7d_warn" "$cfg_7d_crit")
            _ms_bar=$(render_bar "$_ms_pct" "$_ms_color")
            seg_sessions="${seg_sessions} $(muted "|") ${C_LABEL}${_ms_name}${RESET} ${_ms_bar} ${_ms_color}${_ms_pct}%${RESET}"
            _ms_reset_countdown=$(fmt_countdown_epoch "$_ms_reset")
            if [ -n "$_ms_reset_countdown" ]; then
                _ms_reset_marker=$(format_reset_marker "$_ms_reset")
                seg_sessions="${seg_sessions} $(muted "${L_RESET} ${_ms_reset_countdown}${_ms_reset_marker:+ (${_ms_reset_marker})}")"
            fi
        done <<< "$model_scoped_rows"
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

# ---------------------------------------------------------------------------
# Prepaid API credit bar — the API-billing counterpart to the subscription bar.
# Anthropic exposes no credit-balance endpoint (the Console's "Credit balance"
# card is not in the public API), so the balance is a snapshot the user declares
# in config.json and everything spent since it is measured separately.
#
# Two sources, in order. ANTHROPIC_ADMIN_KEY (a different credential from
# ANTHROPIC_API_KEY) buys the authoritative figure from the Admin API cost
# report, covering the whole organization. Failing that — and it always fails on
# an individual account, which Anthropic issues no Admin key for — spend is
# estimated from this machine's own Claude Code transcripts and marked "est.",
# because that view cannot see traffic from the Console, other tools, or other
# machines. Neither available means the declared balance renders on its own,
# with no bar: a bar with no spend figure would read 0% and quietly lie.
#
# The fetch runs DETACHED, never inline. The report paginates at 31 daily
# buckets a page and this script re-renders every couple of seconds, so a
# synchronous multi-page call would stall the prompt for as long as the network
# takes. Each render prints whatever the last completed fetch left on disk and,
# when that is past its TTL, spawns one background refresh behind an mkdir lock.
# ---------------------------------------------------------------------------
balance_warning_line=""
if [ -z "$seg_balance" ] && [ "$cfg_show_balance" = "1" ] \
   && [ "$ACCOUNT_MODE_KIND" != "subscription" ] && [ -n "$cfg_api_credit_balance" ]; then
    _ac_as_of=$(parse_snapshot_moment "$cfg_api_credit_as_of")
    if [ -z "$_ac_as_of" ]; then
        balance_warning_line="${BOLD_RED}${L_BAL_INVALID}${RESET}"
    else
        _ac_dir="$CACHE_ROOT/anthropic-cost"
        mkdir -p "$_ac_dir" 2>/dev/null
        # Keyed by snapshot date: moving the snapshot must not read back a spend
        # total that was accumulated from the old one.
        _ac_file="$_ac_dir/spend-${_ac_as_of}.txt"
        _ac_stamp="$_ac_dir/spend-${_ac_as_of}.stamp"
        _ac_lock="$_ac_dir/fetch.lock"
        _ac_age=$cfg_api_spend_cache_seconds
        [ -f "$_ac_stamp" ] && _ac_age=$(( $(date +%s) - $(file_mtime "$_ac_stamp") ))
        # Where the per-session transcripts live, for the local estimate. Derived
        # from this session's own transcript so a relocated CLAUDE_CONFIG_DIR
        # still resolves, with the stock location as the fallback.
        _ac_projects="$HOME/.claude/projects"
        if [ -n "$transcript_path" ]; then
            _ac_p=$(dirname "$(dirname "$transcript_path")")
            [ -d "$_ac_p" ] && _ac_projects="$_ac_p"
        fi
        _ac_rates=""
        for _i in "${!cfg_model_pricing_patterns[@]}"; do
            _ac_rates+="${cfg_model_pricing_patterns[$_i]}"$'\t'"${cfg_model_pricing_labels[$_i]}"$'\n'
        done
        if [ "$_ac_age" -ge "$cfg_api_spend_cache_seconds" ] \
           && { [ -n "${ANTHROPIC_ADMIN_KEY:-}" ] || command -v python3 >/dev/null 2>&1; }; then
            # A lock left behind by a killed fetcher would wedge refreshes
            # forever, so one older than the worst-case curl budget is abandoned.
            if [ -d "$_ac_lock" ] && [ $(( $(date +%s) - $(file_mtime "$_ac_lock") )) -gt 180 ]; then
                rmdir "$_ac_lock" 2>/dev/null
            fi
            if mkdir "$_ac_lock" 2>/dev/null; then
                _ac_start_iso=$(format_cost_report_start "$_ac_as_of")
                (
                    trap 'rmdir "$_ac_lock" 2>/dev/null' EXIT
                    _src=""; _val=""
                    if [ -n "${ANTHROPIC_ADMIN_KEY:-}" ] && command -v curl >/dev/null 2>&1; then
                        _val=$(anthropic_spend_usd "$_ac_start_iso" "$ANTHROPIC_ADMIN_KEY") && _src="admin"
                    fi
                    if [ -z "$_src" ]; then
                        _val=$(local_spend_usd "$_ac_as_of" "$_ac_projects" "$_ac_rates") && _src="local"
                    fi
                    # Staged through .tmp and promoted by mv so a render reading
                    # mid-write can never see a truncated dollar figure. The
                    # source travels with the figure so the render knows whether
                    # it owes the reader an "est." caveat.
                    if [ -n "$_src" ]; then
                        printf '%s\t%s' "$_src" "$_val" > "${_ac_file}.tmp"
                        mv "${_ac_file}.tmp" "$_ac_file" 2>/dev/null
                    fi
                    # Stamped either way: a rejected key must back off to the TTL
                    # too, not respawn a fetcher on every render.
                    touch "$_ac_stamp" 2>/dev/null
                ) >/dev/null 2>&1 &
                disown 2>/dev/null
            fi
        fi

        _ac_src=""; _ac_spend=""
        [ -f "$_ac_file" ] && IFS=$'\t' read -r _ac_src _ac_spend < "$_ac_file"
        _ac_total=$(printf '%.2f' "$cfg_api_credit_balance")
        _ac_marker=$(format_day_month_epoch "$_ac_as_of")
        _ac_caveat=""
        [ "$_ac_src" = "local" ] && _ac_caveat="${L_BAL_ESTIMATE} · "
        if is_num "$_ac_spend"; then
            _ac_left=$(awk "BEGIN{v=$cfg_api_credit_balance-$_ac_spend; printf \"%.2f\", (v<0?0:v)}")
            _ac_pct=$(awk "BEGIN{ if ($cfg_api_credit_balance>0) { p=($_ac_spend/$cfg_api_credit_balance)*100; printf \"%.0f\", (p>100?100:p) } else print 0 }")
            _ac_color=$(usage_color "$_ac_pct" "$cfg_5h_warn" "$cfg_5h_crit")
            seg_balance="${C_LABEL}${L_BALANCE}${RESET} $(render_bar "$_ac_pct" "$_ac_color") ${_ac_color}${_ac_pct}%${RESET} $(muted "\$${_ac_left}/\$${_ac_total}${_ac_marker:+ (${_ac_caveat}${L_BAL_AS_OF} ${_ac_marker})}")"
        else
            seg_balance="${C_LABEL}${L_BALANCE}${RESET} $(muted "\$${_ac_total}${_ac_marker:+ (${L_BAL_DECLARED} ${_ac_marker})}")"
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

# Today's spend across every session, which is the figure people actually
# budget against — the session cost resets on every /clear, so three clears into
# a day it reads low while the day's real total is several times that.
#
# The ledger is one file per local calendar day, one row per session, holding
# the cost that session had reached when this day first saw it (its baseline)
# and its latest. Today's total is the sum of the differences — so a session
# already running when the option was enabled contributes only what it spends
# from that point, and a session that crosses midnight is split across the two
# days by getting a fresh baseline in the new day's file. Rows unseen for more
# than a day are dropped on every write, so the file cannot grow without limit.
seg_today=""
if [ "$cfg_show_today" = "1" ] && is_num "$cost_usd"; then
    _dc_dir="$CACHE_ROOT/daily-cost"
    mkdir -p "$_dc_dir" 2>/dev/null
    _dc_file="$_dc_dir/$(date +%Y-%m-%d).tsv"
    if [ ! -f "$_dc_file" ]; then
        : > "$_dc_file"
        # First render of a new day is the one moment worth paying for a sweep
        # of the day files that are now too old to ever be read again.
        find "$_dc_dir" -name '*.tsv' -mtime +2 -delete 2>/dev/null
    fi
    _dc_total=$(awk -F'\t' -v sid="${session_id:-unknown}" -v cost="$cost_usd" \
                    -v now="$(date +%s)" -v out="${_dc_file}.tmp" '
        BEGIN { OFS = "\t"; total = 0; seen = 0 }
        NF >= 4 && $1 == sid {
            base = $2 + 0
            # The same id reappearing below its own baseline is a fresh session
            # reusing it; re-baseline rather than subtracting into the negative.
            if (cost + 0 < base) base = cost + 0
            print sid, base, cost, now > out
            total += cost - base
            seen = 1
            next
        }
        NF >= 4 && now - $4 <= 86400 { print $1, $2, $3, $4 > out; total += $3 - $2 }
        END {
            if (!seen) print sid, cost, cost, now > out
            printf "%.2f", total
        }' "$_dc_file" 2>/dev/null)
    mv "${_dc_file}.tmp" "$_dc_file" 2>/dev/null
    if is_num "$_dc_total"; then
        seg_today="$(muted "$L_TODAY") ${C_ACCENT}\$${_dc_total}${RESET}"
    fi
fi

# Extra working directories added with /add-dir, which the stdin JSON already
# carries. The list is unbounded, so it gets the three limits the field needs:
# at most added_dirs_max render, the remainder collapses to "+N more", and each
# name is cut to added_dirs_name_width. In the default "inline" layout this
# rides the identity line beside the project name; "line" gives it a row.
seg_added_dirs=""
added_dirs_inline=""
if [ "$cfg_show_added_dirs" = "1" ] && [ "${#added_dirs[@]}" -gt 0 ]; then
    _ad_shown=0; _ad_names=()
    for _ad in "${added_dirs[@]}"; do
        [ "$_ad_shown" -lt "$cfg_added_dirs_max" ] || break
        _ad_name=$(sanitize_text "$(path_tail "$_ad" 1)")
        [ -n "$_ad_name" ] || continue
        [ "${#_ad_name}" -gt "$cfg_added_dirs_name_width" ] && \
            _ad_name="${_ad_name:0:$cfg_added_dirs_name_width}…"
        _ad_names+=("$_ad_name")
        _ad_shown=$(( _ad_shown + 1 ))
    done
    _ad_more=$(( ${#added_dirs[@]} - _ad_shown ))
    if [ "${#_ad_names[@]}" -gt 0 ] || [ "$_ad_more" -gt 0 ]; then
        if [ "$cfg_added_dirs_layout" = "line" ]; then
            _ad_joined=""
            for _ad_name in "${_ad_names[@]}"; do
                _ad_joined="${_ad_joined}${_ad_joined:+, }${_ad_name}"
            done
            [ "$_ad_more" -gt 0 ] && _ad_joined="${_ad_joined}${_ad_joined:+, }+${_ad_more} more"
            seg_added_dirs="${C_LABEL}${L_ADDED_DIRS}${RESET} ${C_BRANCH}${_ad_joined}${RESET}"
        else
            for _ad_name in "${_ad_names[@]}"; do
                added_dirs_inline="${added_dirs_inline} ${C_BRANCH}+${_ad_name}${RESET}"
            done
            [ "$_ad_more" -gt 0 ] && added_dirs_inline="${added_dirs_inline} $(muted "+${_ad_more} more")"
        fi
    fi
fi
# The inline form belongs to whichever identity segment actually rendered, so a
# custom layout that dropped the repo still shows the session's real reach.
if [ -n "$added_dirs_inline" ]; then
    if [ -n "$seg_repo" ]; then seg_repo="${seg_repo}${added_dirs_inline}"
    elif [ -n "$seg_branch" ]; then seg_branch="${seg_branch}${added_dirs_inline}"
    elif [ -n "$seg_worktree" ]; then seg_worktree="${seg_worktree}${added_dirs_inline}"
    else seg_added_dirs="${C_LABEL}${L_ADDED_DIRS}${RESET}${added_dirs_inline}"
    fi
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

# Prompt-cache expiry. A CLOCK TIME, never a countdown: the statusline only
# repaints while Claude Code is active, so between turns — exactly when the
# cache is draining — a countdown freezes and keeps reporting a number that has
# stopped being true, while a clock time stays correct however stale the render
# is. The tier comes from the transcript's own cache write (5 minutes vs. one
# hour); prompt_cache_ttl_seconds only fills in for transcripts recording
# neither, and never overrides one that does.
seg_prompt_cache=""
if [ "$cfg_show_prompt_cache" = "1" ]; then
    _pc_expiry="$prompt_cache_expiry"
    if [ -z "$_pc_expiry" ] && is_num "$prompt_cache_fallback_base"; then
        _pc_expiry=$(( prompt_cache_fallback_base + cfg_prompt_cache_ttl_seconds ))
    fi
    if is_num "$_pc_expiry"; then
        debug_log "prompt cache: expiry=${_pc_expiry} tier=${prompt_cache_ttl:-fallback ${cfg_prompt_cache_ttl_seconds}}s"
        if [ "$_pc_expiry" -le "$(date +%s)" ]; then
            seg_prompt_cache="${ORANGE}${L_PROMPT_CACHE_EXPIRED}${RESET}"
        else
            _pc_clock=$(format_reset_marker "$_pc_expiry" clock)
            [ -n "$_pc_clock" ] && seg_prompt_cache="$(muted "${L_PROMPT_CACHE} ${_pc_clock}")"
        fi
    fi
fi

# How many times this session's context has already been emptied. Hidden until
# the first one, the same rule Calls and Eff follow: "Ctx 40%" on a session that
# has compacted three times means something very different from the same figure
# at the start, and only the pair says which one you are looking at.
seg_compactions=""
if [ "$cfg_show_compactions" = "1" ] && is_num "$compactions_count" && [ "$compactions_count" -gt 0 ]; then
    seg_compactions="$(muted "${L_COMPACTIONS} ${compactions_count}")"
fi

# Output rate. A total that is still climbing looks the same whether generation
# is fast or crawling; a rate is the reading that shows a degraded endpoint or a
# throttled account while it is happening. The transcript pass emits nothing at
# all when the interval it would divide by is not trustworthy.
seg_speed=""
if [ "$cfg_show_speed" = "1" ] && is_num "$speed_value"; then
    seg_speed="$(muted "${L_SPEED} ${speed_value} ${L_TOKENS_PER_SECOND}")"
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
        mode) printf '%s' "$seg_mode" ;;
        model) printf '%s' "$seg_model" ;;
        repo) printf '%s' "$seg_repo" ;;
        branch) printf '%s' "$seg_branch" ;;
        worktree) printf '%s' "$seg_worktree" ;;
        agent) printf '%s' "$seg_agent" ;;
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
        added_dirs) printf '%s' "$seg_added_dirs" ;;
        prompt_cache) printf '%s' "$seg_prompt_cache" ;;
        today) printf '%s' "$seg_today" ;;
        compactions) printf '%s' "$seg_compactions" ;;
        speed) printf '%s' "$seg_speed" ;;
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
[ -n "$balance_warning_line" ] && out_lines+=("$balance_warning_line")

# The right-aligned run starts at the first segment named in right_align that
# actually renders on that line, marked with a \001 sentinel the width-aware
# awk below turns into padding. A control byte is safe as a marker precisely
# because sanitize_text strips control characters from every value that came
# from outside this script, so none can appear inside a segment.
RIGHT_ALIGN_MARK=$'\001'
LINE_SEPARATOR=" ${C_MUTED}|${RESET} "

IFS='|' read -ra _layout_line_specs <<< "$layout_spec"
for _lspec in "${_layout_line_specs[@]}"; do
    _line=""
    _right_started=0
    IFS=',' read -ra _seg_names <<< "$_lspec"
    for _sn in "${_seg_names[@]}"; do
        _sv=$(segment_value "$_sn")
        if [ -z "$_sv" ]; then
            debug_log "segment '${_sn}' empty (no value, or its display flag is off)"
            continue
        fi
        if [ -n "$_line" ]; then
            if [ "$_right_started" -eq 0 ] && [ -n "$cfg_right_align" ] \
               && [[ ",${cfg_right_align}," == *",${_sn},"* ]]; then
                _line+="$RIGHT_ALIGN_MARK"
                _right_started=1
            else
                _line+="$LINE_SEPARATOR"
            fi
        fi
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
        printf '%s\n' "${out_lines[@]}" | awk -v max="$term_width" \
                                              -v mark="$RIGHT_ALIGN_MARK" \
                                              -v fallback="$LINE_SEPARATOR" '
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
            cut = index(line, mark)
            if (cut > 0) {
                left = substr(line, 1, cut - 1)
                right = substr(line, cut + 1)
                # Stand down whenever there is no room to pad: pushing the line
                # past the terminal edge makes it wrap and costs a whole row,
                # which is strictly worse than the left-packed line it replaced.
                pad = max - visible_width(left) - visible_width(right)
                line = (pad >= 1) ? left sprintf("%" pad "s", "") right : left fallback right
            }
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
        # No known width, so right alignment stands down and the run falls back
        # to an ordinary separator — the same guard the awk above applies.
        debug_log "terminal width unknown; right_align stands down"
        printf '%s\n' "${out_lines[@]//$RIGHT_ALIGN_MARK/$LINE_SEPARATOR}"
    fi
fi

exit 0
