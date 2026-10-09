---
description: Guided super-status configuration — pick a preset, toggle common display fields, preview, then write config.json
allowed-tools: AskUserQuestion, Bash, Read
---

Walk the user through configuring super-status with `AskUserQuestion`, show a
preview of the result, then write `~/.claude/super-status/config.json` for them —
so no one has to hand-edit JSON to turn a line on or pick a preset.

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

Show that `jq .` output as the preview and briefly describe what will render
(e.g. "Full preset + Activity line, expanded layout"). If the user rejects it,
adjust the answers and rebuild — do not write until they accept.

## 4. Write it

Only after the user accepts the preview:

```bash
printf '%s\n' "$NEW" > "$CFG" && echo "wrote $CFG"
```

Then tell the user the statusline re-reads the config on the **next** render, so
they'll see the change on their next turn (no restart needed — unlike install,
which changes settings.json). If `jq` is missing or any step fails, show the
exact output and do not hand-write partial JSON.
