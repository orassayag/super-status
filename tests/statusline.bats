#!/usr/bin/env bats
# Tests for statusline.sh — unit tests source the script (its render flow is
# guarded behind a BASH_SOURCE check), end-to-end tests run it with mock stdin
# payloads under an isolated HOME/XDG_CACHE_HOME.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SCRIPT="$REPO_ROOT/statusline.sh"
    export HOME="$BATS_TEST_TMPDIR/home"
    export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
    mkdir -p "$HOME/.claude/super-status"
    unset SUPER_STATUS_DISABLE SUPER_STATUS_CONFIG ANTHROPIC_BASE_URL OPENROUTER_API_KEY COLUMNS
    # shellcheck disable=SC1090
    source "$SCRIPT"
}

strip_ansi() { sed 's/\x1b\[[0-9;]*m//g' <<< "$1"; }

run_statusline() { # $1 = payload
    run bash -c "printf '%s' \"\$1\" | bash \"\$2\"" _ "$1" "$SCRIPT"
}

MINIMAL_PAYLOAD='{"model":{"display_name":"Opus"},"workspace":{"project_dir":"/a/parent/child"},"context_window":{"used_percentage":25}}'
SUBSCRIPTION_PAYLOAD='{"model":{"display_name":"Opus"},"workspace":{"project_dir":"/a/parent/child"},"context_window":{"used_percentage":25},"rate_limits":{"five_hour":{"used_percentage":63,"resets_at":1900000000},"seven_day":{"used_percentage":44,"resets_at":1900200000}}}'

# --- unit: date parsing -----------------------------------------------------

@test "parse_subscription_date accepts a real dd/MM/yyyy date and round-trips" {
    epoch=$(parse_subscription_date "14/07/2026")
    [ -n "$epoch" ]
    [ "$(format_date_epoch "$epoch")" = "14/07/2026" ]
}

@test "parse_subscription_date rejects the impossible date 31/02/2026" {
    [ -z "$(parse_subscription_date "31/02/2026")" ]
}

@test "parse_subscription_date rejects non-dd/MM/yyyy formats" {
    [ -z "$(parse_subscription_date "2026-07-14")" ]
    [ -z "$(parse_subscription_date "7/14/2026")" ]
    [ -z "$(parse_subscription_date "garbage")" ]
}

@test "add_months_epoch clamps 31/01 to the end of February" {
    epoch=$(add_months_epoch 31 01 2026 1)
    [ "$(format_date_epoch "$epoch")" = "28/02/2026" ]
}

@test "add_months_epoch clamps to 29/02 on a leap year" {
    epoch=$(add_months_epoch 31 01 2028 1)
    [ "$(format_date_epoch "$epoch")" = "29/02/2028" ]
}

@test "add_months_epoch keeps the same day across a normal month boundary" {
    epoch=$(add_months_epoch 14 07 2026 1)
    [ "$(format_date_epoch "$epoch")" = "14/08/2026" ]
}

@test "days_in_month handles leap-year rules (2024 yes, 2100 no, 2000 yes)" {
    [ "$(days_in_month 2 2024)" = "29" ]
    [ "$(days_in_month 2 2100)" = "28" ]
    [ "$(days_in_month 2 2000)" = "29" ]
}

# --- unit: formatting -------------------------------------------------------

@test "fmt_tokens_k formats thousands with one decimal and passes small values through" {
    [ "$(fmt_tokens_k 15234)" = "15.2k" ]
    [ "$(fmt_tokens_k 480)" = "480" ]
    [ -z "$(fmt_tokens_k notanumber)" ]
}

@test "fmt_countdown_epoch clamps past epochs to 0m" {
    [ "$(fmt_countdown_epoch 1000000)" = "0m" ]
}

@test "make_bar renders proportional fill and clamps out-of-range percentages" {
    [ "$(make_bar 50 20)" = "##########----------" ]
    [ "$(make_bar 200 10)" = "##########" ]
    [ "$(make_bar -5 10)" = "----------" ]
}

@test "grade_for maps score bands to letters" {
    [ "$(grade_for 95)" = "A" ]
    [ "$(grade_for 60)" = "C" ]
    [ "$(grade_for 10)" = "F" ]
}

@test "path_tail returns the last N components" {
    [ "$(path_tail "/a/parent/child" 1)" = "child" ]
    [ "$(path_tail "/a/parent/child" 2)" = "parent/child" ]
    [ "$(path_tail "/a/parent/child" 9)" = "a/parent/child" ]
}

@test "resolve_color handles named, 256, and hex colors and rejects garbage" {
    [ "$(resolve_color red)" = $'\033[31m' ]
    [ "$(resolve_color 208)" = $'\033[38;5;208m' ]
    [ "$(resolve_color '#ff0000')" = $'\033[38;2;255;0;0m' ]
    run resolve_color "evil;m"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

# --- e2e: basics ------------------------------------------------------------

@test "kill switch SUPER_STATUS_DISABLE=1 prints nothing and exits 0" {
    run bash -c "printf '%s' \"\$1\" | SUPER_STATUS_DISABLE=1 bash \"\$2\"" _ "$MINIMAL_PAYLOAD" "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "minimal payload renders the model and repo basename" {
    run_statusline "$MINIMAL_PAYLOAD"
    [ "$status" -eq 0 ]
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"Model: Opus"* ]]
    [[ "$plain" == *"Repo: child"* ]]
    [[ "$plain" == *"Context: 25%"* ]]
}

@test "garbage stdin never crashes" {
    run_statusline "this is not json"
    [ "$status" -eq 0 ]
}

@test "no rate_limits means no Sessions line and no subscription warning" {
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" != *"Sessions:"* ]]
    [[ "$plain" != *"SUBSCRIPTION START DATE"* ]]
}

@test "subscription mode without a declared start date shows the reminder" {
    run_statusline "$SUBSCRIPTION_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"Sessions: 5h: 63%"* ]]
    [[ "$plain" == *"SUBSCRIPTION START DATE IS MISSING"* ]]
}

@test "subscription mode with a valid start date shows the cycle bar" {
    echo '"subscription_start_date": "14/07/2026"' > "$HOME/.claude/CLAUDE.md"
    run_statusline "$SUBSCRIPTION_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"Subscription: "* ]]
    [[ "$plain" != *"SUBSCRIPTION START DATE"* ]]
}

@test "subscription mode with an invalid start date shows the INVALID reminder" {
    echo '"subscription_start_date": "31/02/2026"' > "$HOME/.claude/CLAUDE.md"
    run_statusline "$SUBSCRIPTION_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"SUBSCRIPTION START DATE IS INVALID"* ]]
}

# --- e2e: config ------------------------------------------------------------

@test "malformed config.json warns once and still renders with defaults" {
    echo '{broken json' > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    [ "$status" -eq 0 ]
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"SUPER-STATUS CONFIG IS INVALID JSON"* ]]
    [[ "$plain" == *"Model: Opus"* ]]
}

@test "display toggle hides a single field" {
    echo '{"display":{"model":false}}' > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" != *"Model:"* ]]
    [[ "$plain" == *"Repo: child"* ]]
}

@test "path_levels widens the Repo field" {
    echo '{"path_levels":2}' > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"Repo: parent/child"* ]]
}

@test "max_width truncates lines with a trailing ellipsis, ANSI excluded" {
    echo '{"max_width":20}' > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    while IFS= read -r line; do
        plain=$(strip_ansi "$line")
        [ "${#plain}" -le 20 ]
    done <<< "$output"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"…"* ]]
}

@test "custom bar glyphs and width render intact (no mid-glyph byte splits)" {
    echo '{"bar_filled":"█","bar_empty":"░","bar_width":10}' > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"[██░░░░░░░░]"* ]]
}

@test "context_value remaining shows tokens left instead of used/max" {
    echo '{"context_value":"remaining"}' > "$HOME/.claude/super-status/config.json"
    run_statusline '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":25,"context_window_size":200000,"remaining_percentage":50}}'
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"(100k left)"* ]]
    [[ "$plain" != *"k/200k"* ]]
}

@test "custom lines layout reorders and merges segments" {
    echo '{"lines":[["context","model"],["repo"]]}' > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    first_line=$(head -n1 <<< "$plain")
    [[ "$first_line" == "Context: "*"| Model: Opus" ]]
}

@test "minimal preset collapses to the compact layout" {
    echo '{"preset":"minimal"}' > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" != *"Repo:"* ]]
    [[ "$plain" == *"Model: Opus"* ]]
    [ "$(wc -l <<< "$plain" | tr -d '[:space:]')" -le 3 ]
}

# --- e2e: transcript-derived lines ------------------------------------------

write_transcript() {
    cat > "$BATS_TEST_TMPDIR/transcript.jsonl" <<'EOF'
{"timestamp":"2026-07-17T10:00:00.000Z","message":{"role":"assistant","usage":{"input_tokens":100,"cache_creation_input_tokens":200,"cache_read_input_tokens":3000,"output_tokens":500},"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/x/auth.ts"}},{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"/x/b.ts"}},{"type":"tool_use","id":"t3","name":"Grep","input":{"pattern":"foo"}}]}}
{"timestamp":"2026-07-17T10:00:05.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1"},{"type":"tool_result","tool_use_id":"t2"},{"type":"tool_result","tool_use_id":"t3"}]}}
{"timestamp":"2026-07-17T10:01:00.000Z","message":{"role":"assistant","usage":{"input_tokens":150,"output_tokens":700},"content":[{"type":"tool_use","id":"t4","name":"TodoWrite","input":{"todos":[{"content":"Fix auth bug","activeForm":"Fixing auth bug","status":"in_progress"},{"content":"Add tests","status":"pending"},{"content":"Read code","status":"completed"}]}},{"type":"tool_use","id":"t5","name":"Task","input":{"description":"Finding auth code","subagent_type":"Explore","model":"haiku"}},{"type":"tool_use","id":"t6","name":"Edit","input":{"file_path":"/x/auth.ts"}}]}}
{"timestamp":"2026-07-17T10:01:10.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t4"}]}}
EOF
}

transcript_payload() {
    printf '{"model":{"display_name":"Opus"},"session_id":"bats-%s","transcript_path":"%s","context_window":{"used_percentage":25},"cost":{"total_lines_added":45,"total_lines_removed":12}}' \
        "$BATS_TEST_NUMBER" "$BATS_TEST_TMPDIR/transcript.jsonl"
}

@test "tool calls line buckets every call and buckets sum to the total" {
    write_transcript
    run_statusline "$(transcript_payload)"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"Tool Calls (6): Skills: 0 | Code: 1 | Commands: 0 | Read: 3 | MCP Call: 0 | Other: 2"* ]]
    [[ "$plain" == *"Total Tokens: 3.5k in / 1.2k out"* ]]
}

@test "activity, agents, and todo lines are off by default" {
    write_transcript
    run_statusline "$(transcript_payload)"
    plain=$(strip_ansi "$output")
    [[ "$plain" != *"Activity:"* ]]
    [[ "$plain" != *"Agents:"* ]]
    [[ "$plain" != *"Todo:"* ]]
}

@test "preset full enables activity (in-flight marker + grouped counts), agents, and todos" {
    echo '{"preset":"full"}' > "$HOME/.claude/super-status/config.json"
    write_transcript
    run_statusline "$(transcript_payload)"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"Activity: ◐ Edit: auth.ts | ✓ Grep: foo | ✓ Read ×2"* ]]
    [[ "$plain" == *"Agents: ◐ Explore [haiku]: Finding auth code ("* ]]
    [[ "$plain" == *"Todo: ▸ Fixing auth bug (1/3)"* ]]
}

# --- e2e: git enrichment ----------------------------------------------------

@test "git dirty marker and file stats appear on a dirty repo" {
    repo="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    echo x > "$repo/untracked.txt"
    echo '{"preset":"full"}' > "$HOME/.claude/super-status/config.json"
    payload=$(printf '{"model":{"display_name":"Opus"},"workspace":{"project_dir":"%s"},"cwd":"%s","context_window":{"used_percentage":25}}' "$repo" "$repo")
    run_statusline "$payload"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"Branch: main* ?1"* ]]
}

# --- e2e: provider badge ----------------------------------------------------

@test "OpenRouter base URL adds a provider badge to the model segment" {
    run bash -c "printf '%s' \"\$1\" | ANTHROPIC_BASE_URL=https://openrouter.ai/api/v1 bash \"\$2\"" _ "$MINIMAL_PAYLOAD" "$SCRIPT"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"Model: Opus [OpenRouter]"* ]]
}

@test "first-party Anthropic base URL shows no badge" {
    run bash -c "printf '%s' \"\$1\" | ANTHROPIC_BASE_URL=https://api.anthropic.com bash \"\$2\"" _ "$MINIMAL_PAYLOAD" "$SCRIPT"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"Model: Opus"* ]]
    [[ "$plain" != *"["*"]"* ]] || [[ "$plain" != *"Model: Opus ["* ]]
}
