#!/usr/bin/env bats
# Bug corpus: every tests/corpus/*.json case is one past bug as data — the
# payload, the config, the width, and what must appear in the render. On top of
# its own expectations, every case is held to the rules that must always hold:
# exit 0, nothing on stderr, no line wider than the width, every OSC 8 link
# closed on its line, no escape sequence other than colour and OSC 8, and no
# null/NaN/undefined. A new bug becomes a test by adding one file.
#
# Case fields: why, payload (required), config | config_raw, width,
# transcript (rows written to a file; payload.transcript_path is set to it),
# expect.contains / expect.absent (checked on the colour-stripped render),
# expect.raw_contains / expect.raw_absent (checked on the raw bytes).

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SCRIPT="$REPO_ROOT/statusline.sh"
    unset SUPER_STATUS_DISABLE SUPER_STATUS_DEBUG CLAUDE_CONFIG_DIR \
          ANTHROPIC_BASE_URL OPENROUTER_API_KEY ANTHROPIC_ADMIN_KEY COLUMNS
}

check_render() { # $1 case file, $2 stdout file, $3 stderr file, $4 exit status
    python3 - "$@" <<'PY'
import json, re, sys
case_path, out_path, err_path, status = sys.argv[1:5]
with open(case_path, encoding="utf-8") as f:
    case = json.load(f)
with open(out_path, encoding="utf-8", errors="replace") as f:
    raw = f.read()
with open(err_path, encoding="utf-8", errors="replace") as f:
    err = f.read()
width = int(case.get("width") or case.get("config", {}).get("max_width") or 0)
expect = case.get("expect", {})
csi = re.compile(r"\x1b\[[0-9;]*m")
osc8 = re.compile(r"\x1b\]8;;([^\x1b]*)\x1b\\")
failures = []
if status != "0":
    failures.append(f"exit status {status}")
if err.strip():
    failures.append(f"stderr not empty: {err.strip()[:200]!r}")
for number, line in enumerate(raw.split("\n"), 1):
    targets = osc8.findall(line)
    if sum(1 for t in targets if t) != sum(1 for t in targets if not t):
        failures.append(f"line {number}: OSC 8 link left open")
    plain = osc8.sub("", csi.sub("", line))
    leftover = re.findall(r"[\x00-\x08\x0b-\x1f\x7f]", plain)
    if leftover:
        failures.append(f"line {number}: unexpected control bytes {leftover!r}")
    if width and len(plain) > width:
        failures.append(f"line {number}: {len(plain)} columns, width is {width}")
stripped = osc8.sub("", csi.sub("", raw))
if re.search(r"\b(null|NaN|undefined)\b", stripped):
    failures.append("render contains null/NaN/undefined")
for text in expect.get("contains", []):
    if text not in stripped:
        failures.append(f"missing {text!r}")
for text in expect.get("absent", []):
    if text in stripped:
        failures.append(f"unexpected {text!r}")
for text in expect.get("raw_contains", []):
    if text not in raw:
        failures.append(f"raw output missing {text!r}")
for text in expect.get("raw_absent", []):
    if text in raw:
        failures.append(f"raw output has {text!r}")
for failure in failures:
    print(failure)
sys.exit(1 if failures else 0)
PY
}

@test "every corpus case renders and holds the always-on rules" {
    local case_file name work width rc result report="" ran=0
    for case_file in "$REPO_ROOT"/tests/corpus/*.json; do
        name="$(basename "$case_file" .json)"
        work="$BATS_TEST_TMPDIR/$name"
        mkdir -p "$work/home/.claude/super-status" "$work/cache"
        if jq -e 'has("config_raw")' "$case_file" >/dev/null; then
            jq -j '.config_raw' "$case_file" > "$work/home/.claude/super-status/config.json"
        elif jq -e 'has("config")' "$case_file" >/dev/null; then
            jq '.config' "$case_file" > "$work/home/.claude/super-status/config.json"
        fi
        if jq -e 'has("transcript")' "$case_file" >/dev/null; then
            jq -c '.transcript[]' "$case_file" > "$work/transcript.jsonl"
            jq --arg t "$work/transcript.jsonl" '.payload + {transcript_path: $t}' "$case_file" > "$work/payload.json"
        else
            jq '.payload' "$case_file" > "$work/payload.json"
        fi
        width=$(jq -r '.width // empty' "$case_file")
        rc=0
        env HOME="$work/home" XDG_CACHE_HOME="$work/cache" ${width:+COLUMNS="$width"} \
            bash "$SCRIPT" < "$work/payload.json" > "$work/out" 2> "$work/err" || rc=$?
        result=$(check_render "$case_file" "$work/out" "$work/err" "$rc") \
            || report+="${name}:"$'\n'"${result}"$'\n'
        ran=$((ran + 1))
    done
    [ "$ran" -gt 0 ]
    if [ -n "$report" ]; then
        printf '%s' "$report" >&3
        false
    fi
}
