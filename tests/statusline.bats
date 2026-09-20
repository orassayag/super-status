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
    # ANTHROPIC_ADMIN_KEY is unset alongside the rest so a real key in the
    # developer's environment can never turn a test run into live cost-report calls.
    unset SUPER_STATUS_DISABLE SUPER_STATUS_CONFIG ANTHROPIC_BASE_URL OPENROUTER_API_KEY \
          ANTHROPIC_ADMIN_KEY COLUMNS
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

@test "format_reset_marker clock mode shows HH:MM even when the reset is on a later day" {
    # 4h from now, deliberately crossing into tomorrow so day != today.
    tomorrow_epoch=$(( $(date +%s) + 4 * 3600 ))
    while [ "$(date -r "$tomorrow_epoch" +%Y%m%d 2>/dev/null || date -d "@$tomorrow_epoch" +%Y%m%d)" = "$(date +%Y%m%d)" ]; do
        tomorrow_epoch=$(( tomorrow_epoch + 3600 ))
    done
    marker=$(format_reset_marker "$tomorrow_epoch" clock)
    [[ "$marker" =~ ^[0-2][0-9]:[0-5][0-9]$ ]]
}

@test "format_reset_marker default mode shows dd/MM for a later day" {
    next_week=$(( $(date +%s) + 7 * 86400 ))
    marker=$(format_reset_marker "$next_week")
    [[ "$marker" =~ ^[0-3][0-9]/[0-1][0-9]$ ]]
}

# --- unit: formatting -------------------------------------------------------

@test "fmt_tokens_k formats thousands with one decimal and passes small values through" {
    [ "$(fmt_tokens_k 15234)" = "15.2k" ]
    [ "$(fmt_tokens_k 480)" = "480" ]
    [ -z "$(fmt_tokens_k notanumber)" ]
}

@test "parse_iso_epoch reads a UTC ISO-8601 timestamp as UTC, not local time" {
    epoch=$(parse_iso_epoch "2026-07-17T10:00:00Z")
    [ -n "$epoch" ]
    formatted=$(TZ=UTC date -d "@$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
             || TZ=UTC date -r "$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
    [ "$formatted" = "2026-07-17T10:00:00Z" ]
}

@test "parse_iso_epoch returns nothing on unparseable input" {
    [ -z "$(parse_iso_epoch "not-a-date")" ]
}

@test "fmt_countdown_epoch clamps past epochs to 0m" {
    [ "$(fmt_countdown_epoch 1000000)" = "0m" ]
}

@test "make_bar renders proportional fill and clamps out-of-range percentages" {
    [ "$(make_bar 50 10)" = "▮▮▮▮▮▪▪▪▪▪" ]
    [ "$(make_bar 200 10)" = "▮▮▮▮▮▮▮▮▮▮" ]
    [ "$(make_bar -5 10)" = "▪▪▪▪▪▪▪▪▪▪" ]
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
    [[ "$plain" == *"◆ Opus"* ]]
    [[ "$plain" == *"child"* ]]
    [[ "$plain" == *"Ctx "*" 25%"* ]]
}

@test "garbage stdin never crashes" {
    run_statusline "this is not json"
    [ "$status" -eq 0 ]
}

@test "no rate_limits means no sessions bars and no subscription warning" {
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" != *"Reset"* ]]
    [[ "$plain" != *"SUBSCRIPTION START DATE"* ]]
}

@test "subscription mode without a declared start date shows the reminder" {
    run_statusline "$SUBSCRIPTION_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"5h "*" 63% Reset "* ]]
    # both resets carry an absolute "when" marker in parens; these fixtures land
    # on a later day, so the marker is a dd/MM date rather than an HH:MM time
    [[ "$plain" == *"5h "*" 63% Reset "*"("??"/"??")"* ]]
    [[ "$plain" == *" 44% Reset "*"("??"/"??")"* ]]
    [[ "$plain" == *"SUBSCRIPTION START DATE IS MISSING"* ]]
}

@test "subscription mode with a valid start date shows the cycle bar" {
    echo '"subscription_start_date": "14/07/2026"' > "$HOME/.claude/CLAUDE.md"
    run_statusline "$SUBSCRIPTION_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"Sub "* ]]
    [[ "$plain" != *"SUBSCRIPTION START DATE"* ]]
}

@test "subscription mode with an invalid start date shows the INVALID reminder" {
    echo '"subscription_start_date": "31/02/2026"' > "$HOME/.claude/CLAUDE.md"
    run_statusline "$SUBSCRIPTION_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"SUBSCRIPTION START DATE IS INVALID"* ]]
}

# --- e2e: rate-limit persistence across /clear ------------------------------

@test "cached rate limits are restored when a fresh session omits them" {
    # First render carries rate_limits and seeds the cache.
    run_statusline "$SUBSCRIPTION_PAYLOAD"
    [[ "$(strip_ansi "$output")" == *"5h "*" 63% Reset "* ]]
    # A fresh session (post-/clear) has no rate_limits; the bars come from cache.
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"5h "*" 63% Reset "* ]]
    [[ "$plain" == *" 44% Reset "* ]]
}

@test "a cached window whose reset has passed is not resurrected" {
    mkdir -p "$XDG_CACHE_HOME/super-status"
    past=$(( $(date +%s) - 100 ))
    future=$(( $(date +%s) + 400000 ))
    printf '63\t%s\t44\t%s\n' "$past" "$future" \
        > "$XDG_CACHE_HOME/super-status/rate-limits.tsv"
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" != *"63%"* ]]
}

# --- e2e: config ------------------------------------------------------------

@test "malformed config.json warns once and still renders with defaults" {
    echo '{broken json' > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    [ "$status" -eq 0 ]
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"SUPER-STATUS CONFIG IS INVALID JSON"* ]]
    [[ "$plain" == *"◆ Opus"* ]]
}

@test "display toggle hides a single field" {
    echo '{"display":{"model":false}}' > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" != *"Opus"* ]]
    [[ "$plain" == *"child"* ]]
}

@test "path_levels widens the repo location" {
    echo '{"path_levels":2}' > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"parent/child"* ]]
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
    [[ "$plain" == *"██░░░░░░░░"* ]]
}

@test "context_value remaining shows tokens left instead of used/max" {
    echo '{"context_value":"remaining"}' > "$HOME/.claude/super-status/config.json"
    run_statusline '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":25,"context_window_size":200000,"remaining_percentage":50}}'
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"100k left"* ]]
    [[ "$plain" != *"k/200k"* ]]
}

@test "custom lines layout reorders and merges segments" {
    echo '{"lines":[["context","model"],["repo"]]}' > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    first_line=$(head -n1 <<< "$plain")
    [[ "$first_line" == "Ctx "*"| ◆ Opus" ]]
}

@test "minimal preset collapses to the compact layout" {
    echo '{"preset":"minimal"}' > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" != *"child"* ]]
    [[ "$plain" == *"◆ Opus"* ]]
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

@test "tool calls clause shows the total and only the non-zero buckets" {
    write_transcript
    run_statusline "$(transcript_payload)"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"Calls 6 (Read 3, Code 1, Other 2)"* ]]
    [[ "$plain" == *"Tok 3.5k/1.2k"* ]]
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
    [[ "$plain" == *":main* ?1"* ]]
}

# --- e2e: orca/master live run state -----------------------------------------

@test "orchestrator line is off by default even with an active orca status.md" {
    repo="$BATS_TEST_TMPDIR/orca-repo"
    mkdir -p "$repo/.claude"
    git -C "$repo" init -q -b main
    {
        echo '| Agent | Task | Branch | Worktree | Status | Last Update |'
        echo '|---|---|---|---|---|---|'
        echo '| task-billing | task-billing | feature/billing | wt-billing | IN PROGRESS | 2026-07-17T10:00:00Z |'
    } > "$repo/.claude/status.md"
    payload=$(printf '{"model":{"display_name":"Opus"},"workspace":{"project_dir":"%s"},"cwd":"%s","context_window":{"used_percentage":25}}' "$repo" "$repo")
    run_statusline "$payload"
    plain=$(strip_ansi "$output")
    [[ "$plain" != *"Orca:"* ]]
}

@test "orchestrator line buckets orca status.md rows by status" {
    repo="$BATS_TEST_TMPDIR/orca-repo"
    mkdir -p "$repo/.claude"
    git -C "$repo" init -q -b main
    {
        echo '| Agent | Task | Branch | Worktree | Status | Last Update |'
        echo '|---|---|---|---|---|---|'
        echo '| task-auth | task-auth | feature/auth | wt-auth | REBASED & MERGED | 2026-07-17T09:00:00Z |'
        echo '| task-billing | task-billing | feature/billing | wt-billing | IN PROGRESS | 2026-07-17T10:00:00Z |'
        echo '| task-ui | task-ui | feature/ui | wt-ui | CONFLICT — NEEDS YOU | 2026-07-17T09:30:00Z |'
    } > "$repo/.claude/status.md"
    echo '{"preset":"full"}' > "$HOME/.claude/super-status/config.json"
    payload=$(printf '{"model":{"display_name":"Opus"},"workspace":{"project_dir":"%s"},"cwd":"%s","context_window":{"used_percentage":25}}' "$repo" "$repo")
    run_statusline "$payload"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"Orca: 1/3 merged | 1 in progress | 1 conflict ⚠"* ]]
}

@test "orchestrator line hides once every orca row is REBASED & MERGED" {
    repo="$BATS_TEST_TMPDIR/orca-repo"
    mkdir -p "$repo/.claude"
    git -C "$repo" init -q -b main
    {
        echo '| Agent | Task | Branch | Worktree | Status | Last Update |'
        echo '|---|---|---|---|---|---|'
        echo '| task-auth | task-auth | feature/auth | wt-auth | REBASED & MERGED | 2026-07-17T09:00:00Z |'
    } > "$repo/.claude/status.md"
    echo '{"preset":"full"}' > "$HOME/.claude/super-status/config.json"
    payload=$(printf '{"model":{"display_name":"Opus"},"workspace":{"project_dir":"%s"},"cwd":"%s","context_window":{"used_percentage":25}}' "$repo" "$repo")
    run_statusline "$payload"
    plain=$(strip_ansi "$output")
    [[ "$plain" != *"Orca:"* ]]
}

@test "orchestrator line reports the open master stage with elapsed time" {
    repo="$BATS_TEST_TMPDIR/master-repo"
    mkdir -p "$repo/docs/status"
    git -C "$repo" init -q -b main
    spawned=$(date -u -d "-5 minutes" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
           || date -u -v-5M +"%Y-%m-%dT%H:%M:%SZ")
    {
        echo '# Master Stage Plan'
        echo '## Stages'
        echo '- Stage 1: COMMITTED — Scaffold data model'
        echo "- Stage 2: IN PROGRESS — Core calculation engine [window=win-2 spawned=${spawned}]"
        echo '- Stage 3: PLANNED — API endpoints'
    } > "$repo/docs/status/stage-plan.md"
    echo '{"preset":"full"}' > "$HOME/.claude/super-status/config.json"
    payload=$(printf '{"model":{"display_name":"Opus"},"workspace":{"project_dir":"%s"},"cwd":"%s","context_window":{"used_percentage":25}}' "$repo" "$repo")
    run_statusline "$payload"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"Master: Stage 2/3 IN PROGRESS — Core calculation engine (5m"*")"* ]]
    [[ "$plain" == *"1 committed"* ]]
}

@test "orchestrator line hides once every master stage is COMMITTED" {
    repo="$BATS_TEST_TMPDIR/master-repo"
    mkdir -p "$repo/docs/status"
    git -C "$repo" init -q -b main
    {
        echo '## Stages'
        echo '- Stage 1: COMMITTED — Scaffold data model'
    } > "$repo/docs/status/stage-plan.md"
    echo '{"preset":"full"}' > "$HOME/.claude/super-status/config.json"
    payload=$(printf '{"model":{"display_name":"Opus"},"workspace":{"project_dir":"%s"},"cwd":"%s","context_window":{"used_percentage":25}}' "$repo" "$repo")
    run_statusline "$payload"
    plain=$(strip_ansi "$output")
    [[ "$plain" != *"Master:"* ]]
}

# --- e2e: provider badge ----------------------------------------------------

@test "OpenRouter base URL adds a provider badge to the model segment" {
    run bash -c "printf '%s' \"\$1\" | ANTHROPIC_BASE_URL=https://openrouter.ai/api/v1 bash \"\$2\"" _ "$MINIMAL_PAYLOAD" "$SCRIPT"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"◆ Opus [OpenRouter]"* ]]
}

@test "first-party Anthropic base URL shows no badge" {
    run bash -c "printf '%s' \"\$1\" | ANTHROPIC_BASE_URL=https://api.anthropic.com bash \"\$2\"" _ "$MINIMAL_PAYLOAD" "$SCRIPT"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"◆ Opus"* ]]
    [[ "$plain" != *"◆ Opus ["* ]]
}

@test "z.ai base URL adds a z.ai badge" {
    run bash -c "printf '%s' \"\$1\" | ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic bash \"\$2\"" _ "$MINIMAL_PAYLOAD" "$SCRIPT"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"◆ Opus [z.ai]"* ]]
}

@test "an unknown proxy base URL shows its host as the badge" {
    run bash -c "printf '%s' \"\$1\" | ANTHROPIC_BASE_URL=https://proxy.internal:8080/v1 bash \"\$2\"" _ "$MINIMAL_PAYLOAD" "$SCRIPT"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"◆ Opus [proxy.internal:8080]"* ]]
}

@test "provider display toggle off hides the badge" {
    echo '{"display":{"provider":false}}' > "$HOME/.claude/super-status/config.json"
    run bash -c "printf '%s' \"\$1\" | ANTHROPIC_BASE_URL=https://openrouter.ai/api/v1 bash \"\$2\"" _ "$MINIMAL_PAYLOAD" "$SCRIPT"
    plain=$(strip_ansi "$output")
    [[ "$plain" != *"[OpenRouter]"* ]]
}

# --- e2e: effort-level badge ------------------------------------------------

@test "effort.level in the payload adds an effort badge to the model segment" {
    payload='{"model":{"display_name":"Opus"},"workspace":{"project_dir":"/a/parent/child"},"context_window":{"used_percentage":25},"effort":{"level":"high"}}'
    run bash -c "printf '%s' \"\$1\" | bash \"\$2\"" _ "$payload" "$SCRIPT"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"◆ Opus [High]"* ]]
}

@test "no effort field in the payload shows no effort badge" {
    run bash -c "printf '%s' \"\$1\" | bash \"\$2\"" _ "$MINIMAL_PAYLOAD" "$SCRIPT"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"◆ Opus"* ]]
    [[ "$plain" != *"◆ Opus ["* ]]
}

@test "effort display toggle off hides the effort badge" {
    echo '{"display":{"effort":false}}' > "$HOME/.claude/super-status/config.json"
    payload='{"model":{"display_name":"Opus"},"workspace":{"project_dir":"/a/parent/child"},"context_window":{"used_percentage":25},"effort":{"level":"max"}}'
    run bash -c "printf '%s' \"\$1\" | bash \"\$2\"" _ "$payload" "$SCRIPT"
    plain=$(strip_ansi "$output")
    [[ "$plain" != *"[Max]"* ]]
}

# --- e2e: Bedrock / Vertex badges (R5) --------------------------------------

@test "CLAUDE_CODE_USE_BEDROCK=1 adds a Bedrock badge" {
    run bash -c "printf '%s' \"\$1\" | CLAUDE_CODE_USE_BEDROCK=1 bash \"\$2\"" _ "$MINIMAL_PAYLOAD" "$SCRIPT"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"◆ Opus [Bedrock]"* ]]
}

@test "CLAUDE_CODE_USE_VERTEX=1 adds a Vertex badge" {
    run bash -c "printf '%s' \"\$1\" | CLAUDE_CODE_USE_VERTEX=1 bash \"\$2\"" _ "$MINIMAL_PAYLOAD" "$SCRIPT"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"◆ Opus [Vertex]"* ]]
}

# --- unit: humanize_model_id (R5) -------------------------------------------

@test "humanize_model_id turns raw ids into readable names" {
    [ "$(humanize_model_id 'claude-sonnet-4-6-20250101')" = "Claude Sonnet 4.6" ]
    [ "$(humanize_model_id 'claude-3-5-haiku-20241022')" = "Claude 3.5 Haiku" ]
    [ "$(humanize_model_id 'claude-opus-4-1')" = "Claude Opus 4.1" ]
}

@test "humanize_model_id strips a Bedrock provider prefix" {
    [ "$(humanize_model_id 'us.anthropic.claude-opus-4-20250514')" = "Claude Opus 4" ]
}

@test "humanize_model_id returns a non-Claude id unchanged" {
    [ "$(humanize_model_id 'gpt-4o')" = "gpt-4o" ]
}

# --- model_params badge -----------------------------------------------------

@test "model_params_label picks the longest matching pattern, case-insensitively" {
    cfg_model_params_patterns=("Sonnet" "sonnet 5")
    cfg_model_params_labels=("200B" "365B")
    [ "$(model_params_label 'Sonnet 5')" = "365B" ]
    [ "$(model_params_label 'Claude Sonnet 4.6')" = "200B" ]
    [ -z "$(model_params_label 'Haiku 4.5')" ]
    [ -z "$(model_params_label '')" ]
}

@test "model_params renders a parameter badge after the model name" {
    echo '{"model_params":{"opus":"2T"}}' > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"◆ Opus (2T)"* ]]
}

@test "no model_params map leaves the model name untouched" {
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"◆ Opus"* ]]
    [[ "$plain" != *"("* ]]
}

# --- e2e: model_source recovers the real model from the transcript (R5) -----

@test "model_source transcript overrides the stdin display_name" {
    cat > "$BATS_TEST_TMPDIR/tr.jsonl" <<'EOF'
{"timestamp":"2026-07-17T10:00:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-6-20250101","usage":{"input_tokens":10,"output_tokens":5},"content":[]}}
EOF
    echo '{"model_source":"transcript"}' > "$HOME/.claude/super-status/config.json"
    payload=$(printf '{"model":{"display_name":"Opus"},"session_id":"ms1","transcript_path":"%s","context_window":{"used_percentage":25}}' "$BATS_TEST_TMPDIR/tr.jsonl")
    run_statusline "$payload"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"◆ Claude Sonnet 4.6"* ]]
    [[ "$plain" != *"◆ Opus"* ]]
}

@test "model_source auto only overrides behind a proxy" {
    cat > "$BATS_TEST_TMPDIR/tr.jsonl" <<'EOF'
{"timestamp":"2026-07-17T10:00:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-6-20250101","usage":{"input_tokens":10,"output_tokens":5},"content":[]}}
EOF
    echo '{"model_source":"auto"}' > "$HOME/.claude/super-status/config.json"
    payload=$(printf '{"model":{"display_name":"Opus"},"session_id":"ms2","transcript_path":"%s","context_window":{"used_percentage":25}}' "$BATS_TEST_TMPDIR/tr.jsonl")
    # No proxy: keeps the stdin name.
    run_statusline "$payload"
    [[ "$(strip_ansi "$output")" == *"◆ Opus"* ]]
    # Behind a proxy: recovers the real name.
    run bash -c "printf '%s' \"\$1\" | ANTHROPIC_BASE_URL=https://proxy.internal/v1 bash \"\$2\"" _ "$payload" "$SCRIPT"
    [[ "$(strip_ansi "$output")" == *"◆ Claude Sonnet 4.6 [proxy.internal]"* ]]
}

# --- e2e: auto_compact_window re-bases the context percentage (R4) -----------

@test "auto_compact_window re-bases Ctx % onto the configured window" {
    echo '{"auto_compact_window":160000}' > "$HOME/.claude/super-status/config.json"
    # 80k used tokens: 40% of the 200k window, but 50% of a 160k compact window.
    payload='{"model":{"display_name":"Opus"},"context_window":{"used_percentage":40,"context_window_size":200000,"current_usage":{"input_tokens":80000}}}'
    run_statusline "$payload"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"Ctx "*" 50%"* ]]
    [[ "$plain" == *"80k/160k"* ]]
}

@test "without auto_compact_window Ctx % stays on the full window" {
    payload='{"model":{"display_name":"Opus"},"context_window":{"used_percentage":40,"context_window_size":200000,"current_usage":{"input_tokens":80000}}}'
    run_statusline "$payload"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"Ctx "*" 40%"* ]]
}

# --- e2e: external usage snapshot (R3) --------------------------------------

@test "external usage snapshot fills the 5h/Nd bars when stdin omits them" {
    future_five=$(( $(date +%s) + 3000 ))
    future_seven=$(( $(date +%s) + 400000 ))
    snap="$BATS_TEST_TMPDIR/usage.json"
    printf '{"rate_limits":{"five_hour":{"used_percentage":37,"resets_at":%s},"seven_day":{"used_percentage":52,"resets_at":%s}}}' \
        "$future_five" "$future_seven" > "$snap"
    printf '{"external_usage_path":"%s"}' "$snap" > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"5h "*" 37%"* ]]
    [[ "$plain" == *" 52%"* ]]
}

@test "a stale external usage snapshot is ignored" {
    future_five=$(( $(date +%s) + 3000 ))
    future_seven=$(( $(date +%s) + 400000 ))
    snap="$BATS_TEST_TMPDIR/usage.json"
    printf '{"rate_limits":{"five_hour":{"used_percentage":37,"resets_at":%s},"seven_day":{"used_percentage":52,"resets_at":%s}}}' \
        "$future_five" "$future_seven" > "$snap"
    touch -t 202001010000 "$snap"
    printf '{"external_usage_path":"%s","external_usage_max_age":60}' "$snap" > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" != *"37%"* ]]
}

@test "stdin rate_limits win over the external snapshot" {
    future=$(( $(date +%s) + 400000 ))
    snap="$BATS_TEST_TMPDIR/usage.json"
    printf '{"rate_limits":{"five_hour":{"used_percentage":37,"resets_at":%s},"seven_day":{"used_percentage":52,"resets_at":%s}}}' \
        "$future" "$future" > "$snap"
    printf '{"external_usage_path":"%s"}' "$snap" > "$HOME/.claude/super-status/config.json"
    run_statusline "$SUBSCRIPTION_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"5h "*" 63%"* ]]
    [[ "$plain" != *"37%"* ]]
}

@test "external snapshot model_scoped windows render per-model bars" {
    future=$(( $(date +%s) + 400000 ))
    snap="$BATS_TEST_TMPDIR/usage.json"
    printf '{"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":%s},"seven_day":{"used_percentage":20,"resets_at":%s}},"model_scoped":{"Fable":{"used_percentage":66,"resets_at":%s}}}' \
        "$future" "$future" "$future" > "$snap"
    printf '{"external_usage_path":"%s"}' "$snap" > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"Fable "*" 66%"* ]]
}

# --- unit: account-mode + cost-report helpers -------------------------------

@test "seat_tier_label titles a tier id and keeps its multiplier lowercase" {
    [ "$(seat_tier_label "pro")" = "Pro" ]
    [ "$(seat_tier_label "max_5x")" = "Max 5x" ]
    [ "$(seat_tier_label "max_20x")" = "Max 20x" ]
    [ "$(seat_tier_label "team_premium")" = "Team Premium" ]
}

@test "seat_tier_label prints nothing for an absent tier" {
    [ -z "$(seat_tier_label "")" ]
    [ -z "$(seat_tier_label "null")" ]
}

@test "format_cost_report_start keeps the declared calendar day in every zone" {
    # Ahead of UTC is the case that breaks a naive UTC re-render: local midnight
    # on 01/09 is still 31/08 in UTC, which would widen the report by a day.
    epoch=$(TZ="Asia/Jerusalem" parse_subscription_date "01/09/2026")
    [ "$(TZ="Asia/Jerusalem" format_cost_report_start "$epoch")" = "2026-09-01T00:00:00Z" ]
    epoch=$(TZ="America/Los_Angeles" parse_subscription_date "01/09/2026")
    [ "$(TZ="America/Los_Angeles" format_cost_report_start "$epoch")" = "2026-09-01T00:00:00Z" ]
}

@test "format_cost_report_start prints nothing for a non-epoch" {
    [ -z "$(format_cost_report_start "not-a-date")" ]
    [ -z "$(format_cost_report_start "")" ]
}

# --- unit: anthropic_spend_usd (Admin API cost report) ----------------------
# Driven through a stubbed `curl`, so no network and no Admin key is involved.

@test "anthropic_spend_usd sums every bucket across pages and converts cents to dollars" {
    curl() {
        local a url=""
        for a in "$@"; do case "$a" in https://*) url="$a" ;; esac; done
        case "$url" in
            *page=page_two*)
                echo '{"data":[{"results":[{"amount":"250.5"}]}],"has_more":false,"next_page":null}' ;;
            *)
                echo '{"data":[{"results":[{"amount":"1234.56"},{"amount":"65.44"}]},{"results":[]}],"has_more":true,"next_page":"page_two"}' ;;
        esac
    }
    [ "$(anthropic_spend_usd "2026-09-01T00:00:00Z" "sk-ant-admin-x")" = "15.5050" ]
}

@test "anthropic_spend_usd reports a zero-spend window as 0, not as a failure" {
    curl() { echo '{"data":[],"has_more":false,"next_page":null}'; }
    run anthropic_spend_usd "2026-09-01T00:00:00Z" "sk-ant-admin-x"
    [ "$status" -eq 0 ]
    [ "$output" = "0.0000" ]
}

@test "anthropic_spend_usd fails rather than reading a rejected key as zero spend" {
    curl() { echo '{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}'; }
    run anthropic_spend_usd "2026-09-01T00:00:00Z" "bad"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "anthropic_spend_usd fails on an empty response body" {
    curl() { echo ""; }
    run anthropic_spend_usd "2026-09-01T00:00:00Z" "bad"
    [ "$status" -ne 0 ]
}

# --- e2e: account-mode badge ------------------------------------------------

write_oauth_account() { # $1 billingType, $2 seatTier (JSON literal)
    printf '{"oauthAccount":{"billingType":%s,"seatTier":%s}}' "$1" "$2" > "$HOME/.claude.json"
}

@test "prepaid billing renders an API badge ahead of the model segment" {
    write_oauth_account '"prepaid"' 'null'
    run_statusline "$MINIMAL_PAYLOAD"
    [[ "$(strip_ansi "$output")" == *"API | ◆ Opus"* ]]
}

@test "invoice billing also renders the API badge" {
    write_oauth_account '"invoice"' 'null'
    run_statusline "$MINIMAL_PAYLOAD"
    [[ "$(strip_ansi "$output")" == *"API | ◆ Opus"* ]]
}

@test "subscription billing renders Sub when no seat tier is published" {
    write_oauth_account '"subscription"' 'null'
    run_statusline "$MINIMAL_PAYLOAD"
    [[ "$(strip_ansi "$output")" == *"Sub | ◆ Opus"* ]]
}

@test "a published seat tier names the plan instead of Sub" {
    write_oauth_account '"subscription"' '"max_20x"'
    run_statusline "$MINIMAL_PAYLOAD"
    [[ "$(strip_ansi "$output")" == *"Max 20x | ◆ Opus"* ]]
}

@test "stdin rate_limits imply a subscription when ~/.claude.json is absent" {
    run_statusline "$SUBSCRIPTION_PAYLOAD"
    [[ "$(strip_ansi "$output")" == *"Sub | ◆ Opus"* ]]
}

@test "no account record and no rate_limits leaves the badge off" {
    run_statusline "$MINIMAL_PAYLOAD"
    [[ "$(strip_ansi "$output")" == *"◆ Opus"* ]]
}

@test "plan_label overrides the detected mode" {
    write_oauth_account '"prepaid"' 'null'
    echo '{"plan_label":"Max"}' > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    [[ "$(strip_ansi "$output")" == *"Max | ◆ Opus"* ]]
}

@test "behind a proxy the provider badge speaks and the mode badge stays out" {
    write_oauth_account '"prepaid"' 'null'
    ANTHROPIC_BASE_URL="https://openrouter.ai/api" run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"◆ Opus"* ]]
    [[ "$plain" != *"API | ◆ Opus"* ]]
    [[ "$plain" == *"[OpenRouter]"* ]]
}

@test "an explicit plan_label still shows behind a proxy" {
    echo '{"plan_label":"API"}' > "$HOME/.claude/super-status/config.json"
    ANTHROPIC_BASE_URL="https://openrouter.ai/api" run_statusline "$MINIMAL_PAYLOAD"
    [[ "$(strip_ansi "$output")" == *"API | ◆ Opus"* ]]
}

@test "display.mode off hides the badge" {
    write_oauth_account '"prepaid"' 'null'
    echo '{"display":{"mode":false}}' > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"◆ Opus"* ]]
    [[ "$plain" != *"API"* ]]
}

# --- e2e: prepaid API credit bar --------------------------------------------

seed_spend() { # $1 dd/MM/yyyy, $2 dollars spent, $3 source (admin|local, default admin)
    local epoch dir
    epoch=$(parse_subscription_date "$1")
    dir="$XDG_CACHE_HOME/super-status/anthropic-cost"
    mkdir -p "$dir"
    printf '%s\t%s' "${3:-admin}" "$2" > "$dir/spend-${epoch}.txt"
    # Stamped fresh so the render reads this instead of spawning a real fetch.
    touch "$dir/spend-${epoch}.stamp"
}

@test "a fetched spend figure renders a used-percentage credit bar" {
    write_oauth_account '"prepaid"' 'null'
    seed_spend "01/09/2026" "17.37"
    echo '{"api_credit_balance":96.49,"api_credit_as_of":"01/09/2026"}' > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"Bal "*" 18% \$79.12/\$96.49 (as of 01/09)"* ]]
}

@test "spend past the declared balance clamps at 100% and \$0.00 left" {
    write_oauth_account '"prepaid"' 'null'
    seed_spend "01/09/2026" "120.00"
    echo '{"api_credit_balance":96.49,"api_credit_as_of":"01/09/2026"}' > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"100% \$0.00/\$96.49"* ]]
}

@test "with no spend figure yet the balance shows without a bar" {
    write_oauth_account '"prepaid"' 'null'
    echo '{"api_credit_balance":96.49,"api_credit_as_of":"01/09/2026"}' > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"Bal \$96.49 (declared 01/09)"* ]]
    [[ "$plain" != *"Bal ▮"* ]]
    [[ "$plain" != *"Bal ▪"* ]]
}

@test "moving the snapshot date discards the spend cached against the old one" {
    write_oauth_account '"prepaid"' 'null'
    seed_spend "01/09/2026" "17.37"
    echo '{"api_credit_balance":96.49,"api_credit_as_of":"15/09/2026"}' > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"Bal \$96.49 (declared 15/09)"* ]]
    [[ "$plain" != *"79.12"* ]]
}

@test "a missing or malformed snapshot date warns instead of rendering a bar" {
    write_oauth_account '"prepaid"' 'null'
    echo '{"api_credit_balance":96.49,"api_credit_as_of":"2026-09-01"}' > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"API CREDIT SNAPSHOT DATE IS MISSING OR INVALID"* ]]
    [[ "$plain" != *"Bal"* ]]

    echo '{"api_credit_balance":96.49}' > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    [[ "$(strip_ansi "$output")" == *"API CREDIT SNAPSHOT DATE IS MISSING OR INVALID"* ]]
}

@test "the credit bar stays out of a subscription statusline" {
    write_oauth_account '"subscription"' 'null'
    seed_spend "01/09/2026" "17.37"
    echo '{"api_credit_balance":96.49,"api_credit_as_of":"01/09/2026"}' > "$HOME/.claude/super-status/config.json"
    run_statusline "$SUBSCRIPTION_PAYLOAD"
    [[ "$(strip_ansi "$output")" != *"Bal"* ]]
}

@test "declaring no balance leaves the credit bar off entirely" {
    write_oauth_account '"prepaid"' 'null'
    run_statusline "$MINIMAL_PAYLOAD"
    [[ "$(strip_ansi "$output")" != *"Bal"* ]]
}

@test "display.balance off hides the credit bar" {
    write_oauth_account '"prepaid"' 'null'
    seed_spend "01/09/2026" "17.37"
    echo '{"api_credit_balance":96.49,"api_credit_as_of":"01/09/2026","display":{"balance":false}}' > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    [[ "$(strip_ansi "$output")" != *"Bal"* ]]
}

# --- unit: local_spend_usd (transcript-priced fallback) ---------------------

seed_transcript() { # $1 projects dir, $2 iso timestamp, $3 model, $4 usage json
    mkdir -p "$1/proj"
    printf '{"type":"assistant","timestamp":"%s","message":{"model":"%s","usage":%s}}\n' \
        "$2" "$3" "$4" >> "$1/proj/session.jsonl"
}

iso_days_ago() { date -u -v-"$1"d "+%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null \
              || date -u -d "$1 days ago" "+%Y-%m-%dT%H:%M:%S.000Z"; }

epoch_days_ago() { date -v-"$1"d +%s 2>/dev/null || date -d "$1 days ago" +%s; }

@test "local_spend_usd prices uncached input and output at list rates" {
    proj="$BATS_TEST_TMPDIR/projects"
    seed_transcript "$proj" "$(iso_days_ago 1)" "claude-opus-5" \
        '{"input_tokens":1000000,"output_tokens":1000000}'
    # Opus 5 is $5/MTok in, $25/MTok out.
    [ "$(local_spend_usd "$(epoch_days_ago 3)" "$proj")" = "30.0000" ]
}

@test "local_spend_usd prices cache writes at 1.25x/2x and reads at 0.1x input" {
    proj="$BATS_TEST_TMPDIR/projects"
    seed_transcript "$proj" "$(iso_days_ago 1)" "claude-sonnet-5" \
        '{"cache_creation":{"ephemeral_5m_input_tokens":1000000,"ephemeral_1h_input_tokens":1000000},"cache_read_input_tokens":1000000}'
    # Sonnet 5 input is $2/MTok: (1.25 + 2 + 0.1) x 2 = 6.70
    [ "$(local_spend_usd "$(epoch_days_ago 3)" "$proj")" = "6.7000" ]
}

@test "local_spend_usd prices an undifferentiated cache_creation total at the 5m rate" {
    proj="$BATS_TEST_TMPDIR/projects"
    seed_transcript "$proj" "$(iso_days_ago 1)" "claude-sonnet-5" \
        '{"cache_creation_input_tokens":1000000}'
    [ "$(local_spend_usd "$(epoch_days_ago 3)" "$proj")" = "2.5000" ]
}

@test "local_spend_usd excludes messages older than the snapshot" {
    proj="$BATS_TEST_TMPDIR/projects"
    seed_transcript "$proj" "$(iso_days_ago 30)" "claude-opus-5" '{"output_tokens":1000000}'
    seed_transcript "$proj" "$(iso_days_ago 1)" "claude-opus-5" '{"output_tokens":1000000}'
    [ "$(local_spend_usd "$(epoch_days_ago 3)" "$proj")" = "25.0000" ]
}

@test "local_spend_usd ignores non-assistant rows and unpriceable models" {
    proj="$BATS_TEST_TMPDIR/projects"
    mkdir -p "$proj/proj"
    printf '{"type":"user","timestamp":"%s"}\n' "$(iso_days_ago 1)" > "$proj/proj/session.jsonl"
    seed_transcript "$proj" "$(iso_days_ago 1)" "some-other-vendor-model" '{"output_tokens":1000000}'
    [ "$(local_spend_usd "$(epoch_days_ago 3)" "$proj")" = "0.0000" ]
}

@test "local_spend_usd survives a malformed line without losing the rest of the file" {
    proj="$BATS_TEST_TMPDIR/projects"
    mkdir -p "$proj/proj"
    echo '{"type":"assistant", this is not json' > "$proj/proj/session.jsonl"
    seed_transcript "$proj" "$(iso_days_ago 1)" "claude-opus-5" '{"output_tokens":1000000}'
    [ "$(local_spend_usd "$(epoch_days_ago 3)" "$proj")" = "25.0000" ]
}

@test "model_pricing overrides a built-in rate, longest pattern winning" {
    proj="$BATS_TEST_TMPDIR/projects"
    seed_transcript "$proj" "$(iso_days_ago 1)" "claude-opus-5" '{"output_tokens":1000000}'
    rates=$(printf 'opus\t1/2\nopus-5\t100/200\n')
    [ "$(local_spend_usd "$(epoch_days_ago 3)" "$proj" "$rates")" = "200.0000" ]
}

@test "local_spend_usd fails on a missing projects directory or a bad epoch" {
    run local_spend_usd "$(epoch_days_ago 3)" "$BATS_TEST_TMPDIR/nope"
    [ "$status" -ne 0 ]
    run local_spend_usd "not-an-epoch" "$BATS_TEST_TMPDIR"
    [ "$status" -ne 0 ]
}

# --- e2e: the estimate is labelled as one -----------------------------------

@test "a locally-estimated spend figure carries an est. caveat" {
    write_oauth_account '"prepaid"' 'null'
    seed_spend "01/09/2026" "17.37" "local"
    echo '{"api_credit_balance":96.49,"api_credit_as_of":"01/09/2026"}' > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    [[ "$(strip_ansi "$output")" == *"18% \$79.12/\$96.49 (est. · as of 01/09)"* ]]
}

@test "an Admin-API spend figure carries no caveat" {
    write_oauth_account '"prepaid"' 'null'
    seed_spend "01/09/2026" "17.37" "admin"
    echo '{"api_credit_balance":96.49,"api_credit_as_of":"01/09/2026"}' > "$HOME/.claude/super-status/config.json"
    plain=$(strip_ansi "$(run_statusline "$MINIMAL_PAYLOAD"; printf '%s' "$output")")
    [[ "$plain" == *"18% \$79.12/\$96.49 (as of 01/09)"* ]]
    [[ "$plain" != *"est."* ]]
}

@test "the snapshot marker is a date, never a clock time, even when taken today" {
    write_oauth_account '"prepaid"' 'null'
    today=$(date +%d/%m/%Y)
    seed_spend "$today" "17.37" "local"
    printf '{"api_credit_balance":96.49,"api_credit_as_of":"%s"}' "$today" \
        > "$HOME/.claude/super-status/config.json"
    run_statusline "$MINIMAL_PAYLOAD"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"as of $(date +%d/%m))"* ]]
    [[ "$plain" != *"as of 00:00"* ]]
}

# --- unit: parse_snapshot_moment -------------------------------------------

@test "parse_snapshot_moment treats a bare date as midnight" {
    [ "$(parse_snapshot_moment "19/09/2026")" = "$(parse_subscription_date "19/09/2026")" ]
}

@test "parse_snapshot_moment adds the clock time when one is given" {
    midnight=$(parse_subscription_date "19/09/2026")
    [ "$(parse_snapshot_moment "19/09/2026 14:35")" = "$(( midnight + 14 * 3600 + 35 * 60 ))" ]
    [ "$(parse_snapshot_moment "19/09/2026 00:01")" = "$(( midnight + 60 ))" ]
    [ "$(parse_snapshot_moment "19/09/2026 23:59")" = "$(( midnight + 86340 ))" ]
}

@test "parse_snapshot_moment rejects an impossible clock or trailing junk" {
    [ -z "$(parse_snapshot_moment "19/09/2026 24:00")" ]
    [ -z "$(parse_snapshot_moment "19/09/2026 12:60")" ]
    [ -z "$(parse_snapshot_moment "19/09/2026 nope")" ]
    [ -z "$(parse_snapshot_moment "2026-09-19")" ]
    [ -z "$(parse_snapshot_moment "")" ]
}

@test "an afternoon snapshot excludes that morning's spend" {
    proj="$BATS_TEST_TMPDIR/projects"
    day=$(date -u -v-2d +%Y-%m-%d 2>/dev/null || date -u -d "2 days ago" +%Y-%m-%d)
    seed_transcript "$proj" "${day}T02:00:00.000Z" "claude-opus-5" '{"output_tokens":1000000}'
    seed_transcript "$proj" "${day}T23:30:00.000Z" "claude-opus-5" '{"output_tokens":1000000}'
    # Both rows land on the same day; anchoring at 12:00 UTC that day must keep
    # only the later one — the case that breaks if a snapshot is read as midnight.
    noon=$(parse_iso_epoch "${day}T12:00:00Z")
    [ "$(local_spend_usd "$noon" "$proj")" = "25.0000" ]
}

# --- unit: duplicate-row handling ------------------------------------------

@test "local_spend_usd prices a message replayed into another transcript once" {
    proj="$BATS_TEST_TMPDIR/projects"
    mkdir -p "$proj/a" "$proj/b"
    row=$(printf '{"type":"assistant","requestId":"req_1","timestamp":"%s","message":{"id":"msg_1","model":"claude-opus-5","usage":{"output_tokens":1000000}}}' "$(iso_days_ago 1)")
    # The same message, as a resumed session copies it into a second file.
    echo "$row" > "$proj/a/session.jsonl"
    echo "$row" > "$proj/b/session.jsonl"
    [ "$(local_spend_usd "$(epoch_days_ago 3)" "$proj")" = "25.0000" ]
}

@test "local_spend_usd still prices distinct messages and id-less rows" {
    proj="$BATS_TEST_TMPDIR/projects"
    mkdir -p "$proj/a"
    ts=$(iso_days_ago 1)
    {
        printf '{"type":"assistant","timestamp":"%s","message":{"id":"msg_1","model":"claude-opus-5","usage":{"output_tokens":1000000}}}\n' "$ts"
        printf '{"type":"assistant","timestamp":"%s","message":{"id":"msg_2","model":"claude-opus-5","usage":{"output_tokens":1000000}}}\n' "$ts"
        printf '{"type":"assistant","timestamp":"%s","message":{"model":"claude-opus-5","usage":{"output_tokens":1000000}}}\n' "$ts"
    } > "$proj/a/session.jsonl"
    [ "$(local_spend_usd "$(epoch_days_ago 3)" "$proj")" = "75.0000" ]
}
