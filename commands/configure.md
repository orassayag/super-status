---
description: Guided super-status configuration — pick a preset, toggle common display fields, preview the rendered statusline, then write config.json (or "undo" the last change)
allowed-tools: AskUserQuestion, Bash, Read
---

Walk the user through configuring super-status with `AskUserQuestion`, show a
preview of the result, then write `~/.claude/super-status/config.json` for them —
so no one has to hand-edit JSON to turn a line on or pick a preset.

## 0. Undo

If `$ARGUMENTS` is `undo`, skip everything below and swap the saved previous
config back in (running `undo` twice redoes the change):

```bash
CFG="${SUPER_STATUS_CONFIG:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/super-status/config.json}"
UNDO="$(dirname "$CFG")/config.undo.json"
if [ ! -f "$UNDO" ]; then echo "nothing to undo: $UNDO does not exist"; exit 1; fi
SWAP="$CFG.swap"
if [ -f "$CFG" ]; then mv -f "$CFG" "$SWAP"; fi
mv -f "$UNDO" "$CFG"
if [ -f "$SWAP" ]; then mv -f "$SWAP" "$UNDO"; fi
echo "restored previous config:"; cat "$CFG"
```

An undo file holding `{}` stands for "there was no config before" — restoring
it gives the defaults. Tell the user the change shows on their next turn.

## 1. Read the current config

The config path is `${SUPER_STATUS_CONFIG:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/super-status/config.json}`.
With the Bash tool, print the current config (or note that none exists yet):

```bash
CFG="${SUPER_STATUS_CONFIG:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/super-status/config.json}"
if [ -f "$CFG" ]; then echo "--- current ($CFG) ---"; cat "$CFG"; else echo "no config yet: $CFG"; fi
```

Use whatever `preset` / `display.*` / `layout` values it already has as the
defaults you present below, so re-running this command edits rather than resets.

## 2. Ask the user (one `AskUserQuestion` call, multiple questions)

Ask these together; make the option matching the current config the first option
and append " (current)" to its label when a config already exists:

- **Preset** (single-select): `Full` (everything on) · `Essential` (identity +
  git + limits + context + todos/agents) · `Minimal` (model, branch, context,
  sessions — compact layout) · `Custom` (keep current, only apply the toggles below).
- **Extra lines** (multiSelect): `Activity` (live tool activity) · `Agents`
  (running subagents) · `Todos` (todo progress) · `Orchestrator` (/orca-/master
  wave state). These default OFF and are the most-common things people open the
  JSON to enable.
- **Git markers** (multiSelect): `Dirty marker` (`git_dirty`) · `Ahead/behind`
  (`git_ahead_behind`) · `File stats` (`git_file_stats`). Also default OFF.
- **Layout** (single-select): `Expanded` (default multi-line) · `Compact` (3
  lines for small panes).

Only ask about these common toggles — colors, thresholds, bar glyphs, and custom
`lines` layouts stay hand-edited (point the user at the README for those).

## 3. Build the config JSON

Translate the answers into a config object with `jq`, layering on top of any
existing config so unrelated keys survive. Selected preset goes to `preset`
(omit the key entirely for `Custom`); each selected toggle sets its `display.*`
key to `true` and each unselected common toggle to `false`; `layout` is set only
when the user picked one explicitly. Write to a temp file first, validate it
parses, and show it to the user as the **preview** before saving:

```bash
CFG="${SUPER_STATUS_CONFIG:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/super-status/config.json}"
DIR=$(dirname "$CFG"); mkdir -p "$DIR"
BASE="{}"; [ -f "$CFG" ] && BASE=$(cat "$CFG")
# Fill these from the answers:
PRESET="full"            # or "" to omit (Custom)
LAYOUT="expanded"        # or "" to leave untouched
# display flags as jq booleans:
NEW=$(jq -n --argjson base "$BASE" \
  --arg preset "$PRESET" --arg layout "$LAYOUT" \
  --argjson activity false --argjson agents false --argjson todos false --argjson orchestrator false \
  --argjson git_dirty false --argjson git_ahead_behind false --argjson git_file_stats false '
  $base
  | (if $preset == "" then . else .preset = $preset end)
  | (if $layout == "" then . else .layout = $layout end)
  | .display = ((.display // {})
      + { activity: $activity, agents: $agents, todos: $todos, orchestrator: $orchestrator,
          git_dirty: $git_dirty, git_ahead_behind: $git_ahead_behind, git_file_stats: $git_file_stats })
  ')
echo "$NEW" | jq . || { echo "generated invalid JSON — not writing"; exit 1; }
```

Then render the statusline the user will actually get, from a draft file that
`SUPER_STATUS_CONFIG` points at — the real config is not touched yet. The input
is the last real render's payload when one exists, otherwise a sample. The
preview renders into its own cache folder, so it never touches real session state:

```bash
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/super-status"
DRAFT="$CACHE/configure-draft.json"
mkdir -p "$CACHE/preview-cache"
printf '%s\n' "$NEW" > "$DRAFT"
SAMPLE='{"model":{"display_name":"Opus"},"workspace":{"project_dir":"'"$PWD"'"},"cwd":"'"$PWD"'","context_window":{"used_percentage":25}}'
SCRIPT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/super-status/statusline.sh"
{ if [ -s "$CACHE/last-payload.json" ]; then cat "$CACHE/last-payload.json"; else printf '%s' "$SAMPLE"; fi; } \
  | XDG_CACHE_HOME="$CACHE/preview-cache" SUPER_STATUS_CONFIG="$DRAFT" bash "$SCRIPT" \
  | sed "s/$(printf '\033')\[[0-9;]*m//g"
```

Show both the `jq .` output and the rendered lines as the **preview**, and
briefly describe what changed (e.g. "Full preset + Activity line, expanded
layout"). If the user rejects it, adjust the answers and rebuild — do not write
until they accept.

## 4. Write it

Only after the user accepts the preview. The current config is copied to
`config.undo.json` first, so `/super-status:configure undo` can put it back:

```bash
UNDO="$(dirname "$CFG")/config.undo.json"
if [ -f "$CFG" ]; then cp "$CFG" "$UNDO"; else echo '{}' > "$UNDO"; fi
printf '%s\n' "$NEW" > "$CFG" && echo "wrote $CFG (previous saved to $UNDO)"
```

Then tell the user the statusline re-reads the config on the **next** render, so
they'll see the change on their next turn (no restart needed — unlike install,
which changes settings.json), and that `/super-status:configure undo` reverts it. If `jq` is missing or any step fails, show the
exact output and do not hand-write partial JSON.
