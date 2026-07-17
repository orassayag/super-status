---
description: Install the super-status statusline (copy scripts, wire settings.json)
allowed-tools: Bash
---

Install super-status by running its installer from the plugin directory:

```
bash "${CLAUDE_PLUGIN_ROOT}/install.sh"
```

Run that exact command with the Bash tool. It copies `statusline.sh` and
`doctor.sh` into `~/.claude/super-status/`, makes them executable, and patches
the `statusLine` entry in `~/.claude/settings.json` (backing the file up
first, preserving any existing `refreshInterval`, defaulting it to 2 seconds).

After it succeeds, tell the user:
1. The statusline is installed; they must open a **new** Claude Code session
   to see it (statusline config is read at startup).
2. New-in-2.0 lines (Activity, Agents, Todo) and git markers are off by
   default; enabling them takes a one-line config:
   `echo '{"preset": "full"}' > ~/.claude/super-status/config.json`
3. If anything looks wrong later, `bash ~/.claude/super-status/doctor.sh`
   diagnoses and repairs the wiring.

If the install script fails, show the user its exact output — do not try to
hand-patch settings.json yourself.
