#!/usr/bin/env bats
# Config-key parity between statusline.sh and README.md.
#
# Around forty documented options and, until this file, nothing checking them:
# a key renamed in the script and not in the README, or added to one side only,
# would pass every check, and the only person to find out would be a user
# following the documentation and getting no effect. Both sides are mechanically
# readable — the script's config jq names every key it accepts, and the README's
# "Full reference (every key, with its default)" block is valid JSON — so the
# comparison is exact rather than a heuristic.
#
# When this fails, the fix is almost always a README row, not a change here.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

# Both key sets, one per line, from a single pass over the two files.
extract_keys() { # $1 = script|readme
    python3 - "$REPO_ROOT" "$1" <<'PY'
import json
import os
import re
import subprocess
import sys

root, side = sys.argv[1], sys.argv[2]
script = open(os.path.join(root, 'statusline.sh'), encoding='utf-8').read()
readme = open(os.path.join(root, 'README.md'), encoding='utf-8').read()


def script_keys():
    # The config loader's jq program, bounded so the stdin-payload jq (which has
    # the same ["name", s(.path)] shape) can never be read as config keys.
    start = script.index('elif ! _cfg_out=$(jq -r')
    end = script.index("@tsv' \"$CONFIG_FILE\"", start)
    block = script[start:end]

    keys = set(re.findall(r'\["[a-z_]+",\s*s\(\.([a-zA-Z_][\w.]*)\)\]', block))
    # The two keys whose jq is a transform rather than a bare s(.path).
    keys |= {m for m in re.findall(r'\["(lines|right_align)",', block)}
    # The map-valued sections, each spliced in as + ((.name // {}) | ...).
    keys |= set(re.findall(r'\+\s*\(\(\.(\w+)\s*//\s*\{\}\)', block))

    # The three namespaced groups validate their own member names in a case
    # block further down; that block is the authoritative list of what each
    # accepts. Some write one pipe-joined arm, some one arm per key — both
    # shapes are read here, so neither style can hide a key from this check.
    for prefix, marker in (('display', '_k#display_'),
                           ('colors', '_k#color_'),
                           ('thresholds', '_k#threshold_')):
        opened = re.search(r'case "\$\{' + re.escape(marker) + r'\}" in\n', script)
        if not opened:
            raise SystemExit('could not find the %s case block in statusline.sh' % prefix)
        body = script[opened.end():]
        body = body[:body.index('esac')]
        for arm in re.findall(r'^\s*([a-z_|\s]+?)\)', body, re.MULTILINE):
            for name in arm.replace('\n', '').split('|'):
                name = name.strip()
                if name:
                    keys.add('%s.%s' % (prefix, name))
        keys.discard(prefix)
    return keys


def readme_keys():
    heading = '### Full reference (every key, with its default)'
    start = readme.index(heading)
    block = readme[readme.index('```json', start) + len('```json'):]
    block = block[:block.index('```')]
    json.loads(block)  # a malformed reference block is itself a failure
    out = subprocess.run(
        ['jq', '-r', 'paths(type != "object" or length == 0) | join(".")'],
        input=block, capture_output=True, text=True, check=True)
    return {line for line in out.stdout.split('\n') if line}


print('\n'.join(sorted(script_keys() if side == 'script' else readme_keys())))
PY
}

@test "config keys: the script and the README reference agree exactly" {
    script_keys="$(extract_keys script)"
    readme_keys="$(extract_keys readme)"

    undocumented="$(comm -23 <(printf '%s\n' "$script_keys") <(printf '%s\n' "$readme_keys"))"
    stale="$(comm -13 <(printf '%s\n' "$script_keys") <(printf '%s\n' "$readme_keys"))"

    if [ -n "$undocumented" ]; then
        echo "Read by statusline.sh but absent from the README reference block:"
        printf '  %s\n' $undocumented
    fi
    if [ -n "$stale" ]; then
        echo "Documented in the README reference block but never read by statusline.sh:"
        printf '  %s\n' $stale
    fi
    [ -z "$undocumented" ]
    [ -z "$stale" ]
}

@test "every top-level config key also has a row in the README options table" {
    # The reference block gives the shape; the table is what a reader actually
    # reads for meaning. Namespaced keys are documented as grouped rows
    # (display.*, colors.*, thresholds.*, git.*), so only top-level keys are
    # required to appear individually.
    missing=""
    while IFS= read -r key; do
        case "$key" in *.*) continue ;; esac
        grep -qF "\`$key\`" "$REPO_ROOT/README.md" || missing="${missing} ${key}"
    done <<< "$(extract_keys readme)"
    if [ -n "$missing" ]; then
        echo "No options-table row found for:${missing}"
    fi
    [ -z "$missing" ]
}

@test "every layout segment name the script dispatches is documented" {
    segments="$(sed -n '/^segment_value() {/,/^}/p' "$REPO_ROOT/statusline.sh" \
                | sed -n 's/^ *\([a-z_]*\)) printf .*/\1/p' | sort -u)"
    missing=""
    for segment in $segments; do
        grep -qF "\`$segment\`" "$REPO_ROOT/README.md" || missing="${missing} ${segment}"
    done
    if [ -n "$missing" ]; then
        echo "Segment names missing from the README:${missing}"
    fi
    [ -z "$missing" ]
}
