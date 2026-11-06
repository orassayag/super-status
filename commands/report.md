---
description: Build a privacy-masked bug report from the last real statusline render, review it, and file it only with your OK
allowed-tools: AskUserQuestion, Bash, Read
---

Turn the statusline's last real input into a bug report the user can send
without leaking paths or session names. `$ARGUMENTS` is the user's own
description of what looks wrong (may be empty).

## 1. Build the report

Run this with the Bash tool:

```bash
bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/super-status/doctor.sh" --report ${COLUMNS:+--width "$COLUMNS"}
```

It prints Markdown: the environment, config.json with paths masked, the last
input with every string masked to same-length `x` (numbers, timestamps, the
model and the Claude Code version kept), and the statusline rendered from that
masked input. It reads only; nothing is changed. If it exits non-zero, show its
output and stop.

## 2. Show it and ask

Show the whole report to the user verbatim, with their description from
`$ARGUMENTS` on top under `### What looks wrong` (ask for one sentence if it
is empty). Ask them to check nothing private is left — the mask only covers
strings, and config values such as `plan_label` are kept.

Then ask with `AskUserQuestion` (one question): **File it on GitHub** (opens an
issue on orassayag/super-status with `gh`) · **Just show it** (they copy it
themselves) · **Cancel**.

## 3. File it — only after an explicit "File it"

Never file without that answer. Write the exact text they reviewed to a file
and create the issue:

```bash
BODY="${XDG_CACHE_HOME:-$HOME/.cache}/super-status/report-body.md"
# write the reviewed report (description + doctor output) into "$BODY" first
gh issue create --repo orassayag/super-status --title "<short title from the description>" --body-file "$BODY"
```

If `gh` is missing or not logged in, do not try to install or authenticate it:
give the user https://github.com/orassayag/super-status/issues/new and tell
them to paste the report there. Report the issue URL `gh` prints.
