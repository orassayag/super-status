#!/usr/bin/env bats
# Escape-sequence sanitizing, bounded git calls, and the segments added
# alongside them. The sanitize tests are the ones that matter most: they are
# the regression fixture for a transcript that could previously recolour, blink
# or clear the user's terminal from a crafted file name.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SCRIPT="$REPO_ROOT/statusline.sh"
    export HOME="$BATS_TEST_TMPDIR/home"
    export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
    mkdir -p "$HOME/.claude/super-status"
    unset SUPER_STATUS_DISABLE SUPER_STATUS_CONFIG SUPER_STATUS_DEBUG \
          ANTHROPIC_BASE_URL OPENROUTER_API_KEY ANTHROPIC_ADMIN_KEY COLUMNS
    # shellcheck disable=SC1090
    source "$SCRIPT"
}

strip_ansi() { sed 's/\x1b\[[0-9;]*m//g' <<< "$1"; }

run_statusline() { # $1 = payload
    run bash -c "printf '%s' \"\$1\" | bash \"\$2\"" _ "$1" "$SCRIPT"
}

write_config() { printf '%s' "$1" > "$HOME/.claude/super-status/config.json"; }

# A transcript recording a Read of a file whose name carries escape sequences.
# This is the exact fixture the gap was confirmed with: unsanitized, it turned
# part of the statusline red and made it blink.
write_hostile_transcript() { # $1 = path
    python3 - "$1" <<'PY'
import json, sys
rows = [
  {"type": "user", "timestamp": "2026-09-20T11:00:10Z",
   "message": {"role": "user", "content": "go"}},
  {"type": "assistant", "timestamp": "2026-09-20T11:00:20Z",
   "message": {"role": "assistant", "model": "claude-opus-5",
               "usage": {"input_tokens": 5, "output_tokens": 900,
                         "cache_creation": {"ephemeral_1h_input_tokens": 600,
                                            "ephemeral_5m_input_tokens": 0}},
               "content": [{"type": "tool_use", "id": "t1", "name": "Read",
                            "input": {"file_path": "/tmp/ev\x1b[31mIL\x1b[5m.ts\x1b]0;pwned\x07"}}]}},
]
with open(sys.argv[1], "w") as fh:
    for row in rows:
        fh.write(json.dumps(row) + "\n")
PY
}

# --- unit: sanitize_text ----------------------------------------------------

@test "sanitize_text strips a CSI colour sequence and leaves the text" {
    [ "$(sanitize_text $'ev\033[31mIL\033[5m.ts')" = "evIL.ts" ]
}

@test "sanitize_text strips an OSC sequence terminated by BEL or ST" {
    [ "$(sanitize_text $'a\033]0;retitle\007b')" = "ab" ]
    [ "$(sanitize_text $'a\033]8;;http://x\033\\b')" = "ab" ]
}

@test "sanitize_text strips a screen-clear and a bare ESC" {
    [ "$(sanitize_text $'x\033[2Jy')" = "xy" ]
    [ "$(sanitize_text $'x\033y')" = "xy" ]
}

@test "sanitize_text strips bidi overrides that disguise what a line says" {
    [ "$(sanitize_text $'gpj.\xe2\x80\xaeexe.txt')" = "gpj.exe.txt" ]
}

@test "sanitize_text turns remaining control characters into spaces" {
    [ "$(sanitize_text $'a\tb\nc')" = "a b c" ]
    [ "$(sanitize_text $'a\001b')" = "a b" ]
}

@test "sanitize_text leaves ordinary and multi-byte text untouched" {
    [ "$(sanitize_text 'src/auth.ts')" = "src/auth.ts" ]
    [ "$(sanitize_text 'héllo — wörld ▮▪')" = "héllo — wörld ▮▪" ]
}

@test "sanitize_text terminates on a string that is only escape bytes" {
    [ -z "$(sanitize_text $'\033\033\033')" ]
}

# --- unit: safe_hyperlink ---------------------------------------------------

@test "safe_hyperlink emits an OSC 8 link for an absolute path" {
    link=$(safe_hyperlink "/tmp/auth.ts" "auth.ts")
    [[ "$link" == *"file:///tmp/auth.ts"* ]]
    [[ "$link" == *"auth.ts"* ]]
}

@test "safe_hyperlink percent-escapes a space and a multi-byte path" {
    link=$(safe_hyperlink "/tmp/my file.ts" "x")
    [[ "$link" == *"/tmp/my%20file.ts"* ]]
    link=$(safe_hyperlink "/tmp/café.ts" "x")
    [[ "$link" == *"%C3%A9"* ]]
}

@test "safe_hyperlink refuses a relative path and an empty label" {
    run safe_hyperlink "relative/path.ts" "x"
    [ "$status" -ne 0 ]
    run safe_hyperlink "/tmp/x.ts" ""
    [ "$status" -ne 0 ]
}

@test "safe_hyperlink cannot be used to smuggle a sequence through the address" {
    link=$(safe_hyperlink $'/tmp/a\033]0;pwned\007b.ts' "label")
    # One OSC 8 opener, one closer, and nothing else ESC-introduced between.
    [ "$(grep -c . <<< "$link")" -eq 1 ]
    [[ "$link" != *$'\033]0;'* ]]
}

# --- end-to-end: the hostile transcript -------------------------------------

@test "a crafted file name reaches the Activity line as plain text" {
    transcript="$BATS_TEST_TMPDIR/hostile.jsonl"
    write_hostile_transcript "$transcript"
    write_config '{"display":{"activity":true}}'
    run_statusline "{\"model\":{\"display_name\":\"Opus\"},\"session_id\":\"h1\",\"transcript_path\":\"$transcript\",\"workspace\":{\"project_dir\":\"/a/b\"}}"
    [ "$status" -eq 0 ]
    line=$(grep Activity <<< "$output")
    [[ "$(strip_ansi "$line")" == *"evIL.ts"* ]]
    # Nothing the transcript carried survives into the raw bytes: no blink,
    # no OSC title-set, no BEL. Checked unstripped, because strip_ansi would
    # remove the very sequences this is looking for.
    [[ "$line" != *$'\033[5m'* ]]
    [[ "$line" != *$'\033]0;'* ]]
    [[ "$line" != *$'\007'* ]]
}

@test "a crafted model name and project path are cleaned before rendering" {
    esc='\u001b'
    run_statusline "{\"model\":{\"display_name\":\"Op${esc}[5mus\"},\"workspace\":{\"project_dir\":\"/a/pa${esc}[5mrent\"}}"
    [ "$status" -eq 0 ]
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"Opus"* ]]
    [[ "$plain" == *"parent"* ]]
    # super-status never emits blink, so one here came from the payload.
    [[ "$output" != *$'\033[5m'* ]]
}

# --- git_run ----------------------------------------------------------------

@test "git_run sets the no-prompt and no-lock environment on every call" {
    # A stub git that reports the environment it was actually handed — the only
    # way to prove the guards reach the child rather than merely being written.
    stub="$BATS_TEST_TMPDIR/envstub"
    mkdir -p "$stub"
    printf '#!/bin/sh\nprintf "%%s %%s %%s" "$GIT_TERMINAL_PROMPT" "$GIT_OPTIONAL_LOCKS" "$GCM_INTERACTIVE"\n' > "$stub/git"
    chmod +x "$stub/git"
    output=$(PATH="$stub:$PATH" git_run rev-parse)
    [ "$output" = "0 0 Never" ]
}

@test "git_run abandons a call that exceeds the timeout" {
    if [ -z "$GIT_TIMEOUT_CMD" ]; then
        skip "no timeout/gtimeout on this machine; git_run runs unbounded by design"
    fi
    cfg_git_timeout=1
    stub="$BATS_TEST_TMPDIR/stub"
    mkdir -p "$stub"
    printf '#!/bin/sh\nsleep 30\n' > "$stub/git"
    chmod +x "$stub/git"
    start=$(date +%s)
    PATH="$stub:$PATH" run git_run -C "$BATS_TEST_TMPDIR" status
    [ $(( $(date +%s) - start )) -lt 10 ]
    [ "$status" -ne 0 ]
}

@test "a git call that times out degrades to no branch, not a broken render" {
    stub="$BATS_TEST_TMPDIR/stub"
    mkdir -p "$stub"
    printf '#!/bin/sh\nexit 1\n' > "$stub/git"
    chmod +x "$stub/git"
    run env "PATH=$stub:$PATH" bash -c "printf '%s' \"\$1\" | bash \"\$2\"" _ \
        '{"model":{"display_name":"Opus"},"workspace":{"project_dir":"/a/parent/child"}}' "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$(strip_ansi "$output")" == *"child"* ]]
}

# --- jj ---------------------------------------------------------------------

@test "jj.enabled without a .jj directory leaves the git branch alone" {
    repo="$BATS_TEST_TMPDIR/plain"
    mkdir -p "$repo"
    git -C "$repo" init -q -b trunk
    git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    write_config '{"jj":{"enabled":true}}'
    run_statusline "{\"model\":{\"display_name\":\"Opus\"},\"cwd\":\"$repo\",\"workspace\":{\"project_dir\":\"$repo\"}}"
    [[ "$(strip_ansi "$output")" == *"trunk"* ]]
}

@test "jj stays off entirely when the flag is not set, .jj directory or not" {
    repo="$BATS_TEST_TMPDIR/both"
    mkdir -p "$repo/.jj"
    git -C "$repo" init -q -b trunk
    git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    run_statusline "{\"model\":{\"display_name\":\"Opus\"},\"cwd\":\"$repo\",\"workspace\":{\"project_dir\":\"$repo\"}}"
    [[ "$(strip_ansi "$output")" == *"trunk"* ]]
}

# --- added dirs -------------------------------------------------------------

PAYLOAD_WITH_DIRS='{"model":{"display_name":"Opus"},"workspace":{"project_dir":"/a/proj","added_dirs":["/x/shared-lib","/x/other","/x/third","/x/fourth","/x/fifth","/x/sixth"]}}'

@test "added dirs ride the identity line inline by default" {
    write_config '{"display":{"added_dirs":true}}'
    run_statusline "$PAYLOAD_WITH_DIRS"
    [[ "$(strip_ansi "$output")" == *"proj +shared-lib +other"* ]]
}

@test "added dirs collapse past the limit and can take their own line" {
    write_config '{"display":{"added_dirs":true},"added_dirs_layout":"line","added_dirs_max":2}'
    run_statusline "$PAYLOAD_WITH_DIRS"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"Added dirs: shared-lib, other, +4 more"* ]]
}

@test "added dirs names are cut to the configured width" {
    write_config '{"display":{"added_dirs":true},"added_dirs_layout":"line","added_dirs_name_width":4}'
    run_statusline '{"model":{"display_name":"Opus"},"workspace":{"project_dir":"/a/proj","added_dirs":["/x/averylongdirectoryname"]}}'
    [[ "$(strip_ansi "$output")" == *"aver…"* ]]
}

@test "added dirs render nothing when the display flag is off" {
    run_statusline "$PAYLOAD_WITH_DIRS"
    [[ "$(strip_ansi "$output")" != *"shared-lib"* ]]
}

# --- compactions / speed / prompt cache -------------------------------------

write_rich_transcript() { # $1 = path, $2 = compaction count
    python3 - "$1" "$2" <<'PY'
import json, sys
path, compactions = sys.argv[1], int(sys.argv[2])
rows = []
for _ in range(compactions):
    rows.append({"type": "system", "subtype": "compact_boundary",
                 "timestamp": "2026-09-20T10:00:00Z"})
rows.append({"type": "user", "timestamp": "2026-09-20T11:00:00Z",
             "message": {"role": "user", "content": "go"}})
rows.append({"type": "assistant", "timestamp": "2026-09-20T11:00:10Z",
             "message": {"role": "assistant", "model": "claude-opus-5",
                         "usage": {"input_tokens": 5, "output_tokens": 1000,
                                   "cache_creation": {"ephemeral_5m_input_tokens": 600,
                                                      "ephemeral_1h_input_tokens": 0}},
                         "content": []}})
with open(path, "w") as fh:
    for row in rows:
        fh.write(json.dumps(row) + "\n")
PY
}

@test "the compaction count renders once there has been one, and not before" {
    transcript="$BATS_TEST_TMPDIR/c.jsonl"
    write_config '{"display":{"compactions":true}}'

    write_rich_transcript "$transcript" 0
    run_statusline "{\"model\":{\"display_name\":\"Opus\"},\"session_id\":\"c0\",\"transcript_path\":\"$transcript\",\"workspace\":{\"project_dir\":\"/a/b\"}}"
    [[ "$(strip_ansi "$output")" != *"Compactions"* ]]

    write_rich_transcript "$transcript" 3
    run_statusline "{\"model\":{\"display_name\":\"Opus\"},\"session_id\":\"c3\",\"transcript_path\":\"$transcript\",\"workspace\":{\"project_dir\":\"/a/b\"}}"
    [[ "$(strip_ansi "$output")" == *"Compactions: 3"* ]]
}

@test "output speed renders as a rate over a plausible interval" {
    transcript="$BATS_TEST_TMPDIR/s.jsonl"
    write_rich_transcript "$transcript" 0
    write_config '{"display":{"speed":true}}'
    run_statusline "{\"model\":{\"display_name\":\"Opus\"},\"session_id\":\"sp\",\"transcript_path\":\"$transcript\",\"workspace\":{\"project_dir\":\"/a/b\"}}"
    # 1000 output tokens over the 10s between the user row and the response.
    [[ "$(strip_ansi "$output")" == *"out: 100.0 tok/s"* ]]
}

@test "output speed is omitted when the interval is not trustworthy" {
    transcript="$BATS_TEST_TMPDIR/idle.jsonl"
    python3 - "$transcript" <<'PY'
import json, sys
rows = [
  {"type": "user", "timestamp": "2026-09-20T09:00:00Z",
   "message": {"role": "user", "content": "go"}},
  {"type": "assistant", "timestamp": "2026-09-20T11:00:00Z",
   "message": {"role": "assistant", "model": "claude-opus-5",
               "usage": {"input_tokens": 5, "output_tokens": 1000}, "content": []}},
]
with open(sys.argv[1], "w") as fh:
    for row in rows:
        fh.write(json.dumps(row) + "\n")
PY
    write_config '{"display":{"speed":true}}'
    run_statusline "{\"model\":{\"display_name\":\"Opus\"},\"session_id\":\"idle\",\"transcript_path\":\"$transcript\",\"workspace\":{\"project_dir\":\"/a/b\"}}"
    [[ "$(strip_ansi "$output")" != *"tok/s"* ]]
}

@test "the prompt cache expiry is a clock time, one hour out for a 1h write" {
    transcript="$BATS_TEST_TMPDIR/pc.jsonl"
    write_hostile_transcript "$transcript"
    write_config '{"display":{"prompt_cache":true}}'
    run_statusline "{\"model\":{\"display_name\":\"Opus\"},\"session_id\":\"pc\",\"transcript_path\":\"$transcript\",\"workspace\":{\"project_dir\":\"/a/b\"}}"
    plain=$(strip_ansi "$output")
    # The fixture's cache write is well in the past, so it must read expired
    # rather than inventing a future clock time.
    [[ "$plain" == *"expired"* ]]
}

@test "a 1h cache write expires an hour after it, not five minutes after" {
    transcript="$BATS_TEST_TMPDIR/fresh.jsonl"
    python3 - "$transcript" <<'PY'
import json, sys, time
from datetime import datetime, timezone
now = datetime.fromtimestamp(time.time() - 60, tz=timezone.utc).isoformat().replace('+00:00', 'Z')
rows = [{"type": "assistant", "timestamp": now,
         "message": {"role": "assistant", "model": "claude-opus-5",
                     "usage": {"input_tokens": 5, "output_tokens": 10,
                               "cache_creation": {"ephemeral_1h_input_tokens": 600,
                                                  "ephemeral_5m_input_tokens": 0}},
                     "content": []}}]
with open(sys.argv[1], "w") as fh:
    for row in rows:
        fh.write(json.dumps(row) + "\n")
PY
    write_config '{"display":{"prompt_cache":true}}'
    run_statusline "{\"model\":{\"display_name\":\"Opus\"},\"session_id\":\"fresh\",\"transcript_path\":\"$transcript\",\"workspace\":{\"project_dir\":\"/a/b\"}}"
    plain=$(strip_ansi "$output")
    [[ "$plain" == *"⏱ until"* ]]
    [[ "$plain" != *"expired"* ]]
}

# --- today's spend ----------------------------------------------------------

@test "today's spend counts only what a session spends after it is first seen" {
    write_config '{"display":{"today":true}}'
    base='{"model":{"display_name":"Opus"},"session_id":"%s","workspace":{"project_dir":"/a/b"},"cost":{"total_cost_usd":%s}}'

    run_statusline "$(printf "$base" one 0.42)"
    [[ "$(strip_ansi "$output")" == *'Today $0.00'* ]]

    run_statusline "$(printf "$base" one 1.92)"
    [[ "$(strip_ansi "$output")" == *'Today $1.50'* ]]

    # A second session joining mid-day contributes nothing until it spends.
    run_statusline "$(printf "$base" two 3.00)"
    [[ "$(strip_ansi "$output")" == *'Today $1.50'* ]]

    run_statusline "$(printf "$base" two 3.50)"
    [[ "$(strip_ansi "$output")" == *'Today $2.00'* ]]
}

@test "the day ledger drops rows unseen for more than a day" {
    write_config '{"display":{"today":true}}'
    ledger="$XDG_CACHE_HOME/super-status/daily-cost/$(date +%Y-%m-%d).tsv"
    mkdir -p "$(dirname "$ledger")"
    printf 'stale\t0\t99\t1\n' > "$ledger"
    run_statusline '{"model":{"display_name":"Opus"},"session_id":"live","workspace":{"project_dir":"/a/b"},"cost":{"total_cost_usd":1}}'
    run grep -c stale "$ledger"
    [ "$output" = "0" ]
}

# --- right-aligned run ------------------------------------------------------

@test "right_align pushes the named run to the right edge" {
    write_config '{"lines":[["model","context"]],"right_align":["context"],"max_width":80}'
    run_statusline '{"model":{"display_name":"Opus"},"workspace":{"project_dir":"/a/b"},"context_window":{"used_percentage":40}}'
    line=$(strip_ansi "$output")
    [ "${#line}" -eq 80 ]
    # The whole Ctx run, bar and both values, sits flush against the right edge.
    [[ "$line" == *"0k/200k" ]]
    [[ "$line" == *"  Ctx "* ]]
}

@test "right_align stands down when the width is unknown" {
    write_config '{"lines":[["model","context"]],"right_align":["context"]}'
    run_statusline '{"model":{"display_name":"Opus"},"workspace":{"project_dir":"/a/b"},"context_window":{"used_percentage":40}}'
    # Falls back to the ordinary separator rather than emitting the sentinel.
    [[ "$output" != *$'\001'* ]]
    [[ "$(strip_ansi "$output")" == *"| Ctx"* ]]
}

@test "right_align stands down rather than wrapping when there is no room" {
    write_config '{"lines":[["model","context"]],"right_align":["context"],"max_width":24}'
    run_statusline '{"model":{"display_name":"Opus"},"workspace":{"project_dir":"/a/b"},"context_window":{"used_percentage":40}}'
    [[ "$output" != *$'\001'* ]]
    while IFS= read -r line; do
        [ "${#line}" -le 24 ] || { [ "$(strip_ansi "$line" | wc -c)" -le 26 ]; }
    done <<< "$(strip_ansi "$output")"
}

# --- debug switch -----------------------------------------------------------

@test "SUPER_STATUS_DEBUG writes only to standard error" {
    run bash -c "printf '%s' \"\$1\" | SUPER_STATUS_DEBUG=1 bash \"\$2\" 2>/dev/null" _ \
        '{"model":{"display_name":"Opus"},"workspace":{"project_dir":"/a/b"}}' "$SCRIPT"
    [[ "$output" != *"super-status:"* ]]

    run bash -c "printf '%s' \"\$1\" | SUPER_STATUS_DEBUG=1 bash \"\$2\" 2>&1 >/dev/null" _ \
        '{"model":{"display_name":"Opus"},"workspace":{"project_dir":"/a/b"}}' "$SCRIPT"
    [[ "$output" == *"super-status:"* ]]
}

@test "the debug switch names the reason a segment came out empty" {
    run bash -c "printf '%s' \"\$1\" | SUPER_STATUS_DEBUG=1 bash \"\$2\" 2>&1 >/dev/null" _ \
        '{"model":{"display_name":"Opus"},"workspace":{"project_dir":"/a/b"}}' "$SCRIPT"
    [[ "$output" == *"segment 'sessions' empty"* ]]
    [[ "$output" == *"rate limits:"* ]]
}

@test "nothing is written to standard error without the switch" {
    run bash -c "printf '%s' \"\$1\" | bash \"\$2\" 2>&1 >/dev/null" _ \
        '{"model":{"display_name":"Opus"},"workspace":{"project_dir":"/a/b"}}' "$SCRIPT"
    [ -z "$output" ]
}

# --- external usage write path ----------------------------------------------

@test "the stdin rate-limit windows are published to external_usage_write_path" {
    target="$BATS_TEST_TMPDIR/usage.json"
    write_config "{\"external_usage_write_path\":\"$target\"}"
    run_statusline '{"model":{"display_name":"Opus"},"workspace":{"project_dir":"/a/b"},"rate_limits":{"five_hour":{"used_percentage":63,"resets_at":1900000000},"seven_day":{"used_percentage":44,"resets_at":1900200000}}}'
    [ -f "$target" ]
    [ "$(jq -r '.rate_limits.five_hour.used_percentage' "$target")" = "63" ]
    [ "$(jq -r '.rate_limits.seven_day.resets_at' "$target")" = "1900200000" ]
}

@test "a fresher snapshot from the feeder is never replaced with an older one" {
    target="$BATS_TEST_TMPDIR/usage.json"
    # A snapshot for a LATER window than the one stdin is about to offer.
    jq -n '{rate_limits:{five_hour:{used_percentage:5,resets_at:1900009999},
                         seven_day:{used_percentage:5,resets_at:1900209999}}}' > "$target"
    write_config "{\"external_usage_write_path\":\"$target\"}"
    run_statusline '{"model":{"display_name":"Opus"},"workspace":{"project_dir":"/a/b"},"rate_limits":{"five_hour":{"used_percentage":63,"resets_at":1900000000},"seven_day":{"used_percentage":44,"resets_at":1900200000}}}'
    [ "$(jq -r '.rate_limits.five_hour.resets_at' "$target")" = "1900009999" ]
}

@test "a relative or non-json write path is refused" {
    write_config '{"external_usage_write_path":"relative/usage.json"}'
    run_statusline '{"model":{"display_name":"Opus"},"workspace":{"project_dir":"/a/b"},"rate_limits":{"five_hour":{"used_percentage":63,"resets_at":1900000000},"seven_day":{"used_percentage":44,"resets_at":1900200000}}}'
    [ "$status" -eq 0 ]
    [ ! -e "relative/usage.json" ]

    write_config "{\"external_usage_write_path\":\"$BATS_TEST_TMPDIR/usage.txt\"}"
    run_statusline '{"model":{"display_name":"Opus"},"workspace":{"project_dir":"/a/b"},"rate_limits":{"five_hour":{"used_percentage":63,"resets_at":1900000000},"seven_day":{"used_percentage":44,"resets_at":1900200000}}}'
    [ ! -e "$BATS_TEST_TMPDIR/usage.txt" ]
}

# --- hyperlinks -------------------------------------------------------------

@test "hyperlinks are off by default and opt in cleanly" {
    transcript="$BATS_TEST_TMPDIR/h.jsonl"
    write_hostile_transcript "$transcript"
    payload="{\"model\":{\"display_name\":\"Opus\"},\"session_id\":\"hl\",\"transcript_path\":\"$transcript\",\"workspace\":{\"project_dir\":\"/a/b\"}}"

    write_config '{"display":{"activity":true}}'
    run_statusline "$payload"
    [[ "$output" != *"file://"* ]]

    write_config '{"display":{"activity":true},"hyperlinks":true}'
    run_statusline "$payload"
    [[ "$output" == *"file:///tmp/evIL.ts"* ]]
}
