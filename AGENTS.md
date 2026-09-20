# AGENTS.md — installing super-status on someone's behalf

## For humans

You do not need this file. [README.md](README.md) presents three install routes
and lets you pick. This one exists because "install super-status for me" is a
thing people ask an agent, and three routes with no stated preference means the
agent picks one — possibly the wrong one for that machine.

Below is **one** ordered path. Follow it top to bottom.

<agent_workflow>

## 0. Prerequisites — check, do not assume

```
jq --version
python3 --version
bash --version
claude --version
```

- `jq` and `python3` are **required**. Missing either, stop and tell the user
  which one and the install command for their platform (`brew install jq`,
  `sudo apt-get install -y jq`).
- Bash 3.2 is fine — the script targets it deliberately. Do not "upgrade bash"
  as part of installing this.
- `tokei` and `jj` are **optional**. Their segments simply do not render
  without them. Never install them as part of this.
- On Windows, run everything below inside **Git Bash or WSL**, never PowerShell
  or `cmd`.

## 1. Install

From a clone of this repository:

```
./install.sh
```

That is the whole step. Do not hand-edit `~/.claude/settings.json` to wire the
statusline yourself — `install.sh` owns that, and a hand-written entry is the
most common cause of "it installed but nothing renders".

If the user explicitly asked for the plugin route instead, that is
`/plugin install super-status` from inside Claude Code, and you are done —
skip to step 4.

## 2. Verify the install wiring

```
./doctor.sh
```

`doctor.sh` answers "is the install correct". Fix anything it reports before
going further. Do not proceed on a warning you did not read.

## 3. Verify it actually renders

```
echo '{"model":{"display_name":"Opus"},"workspace":{"project_dir":"'"$PWD"'"},"context_window":{"used_percentage":25}}' | bash statusline.sh
```

You should see at least one line naming the model and the folder. Nothing at
all, or an error, means stop and report — do not start editing the script.

If a segment you expected is missing, that is a different question from "is the
install correct", and `doctor.sh` will not answer it. Use:

```
SUPER_STATUS_DEBUG=1 bash statusline.sh < payload.json 2>debug.log
```

It traces where each value came from and why a segment came out empty, on
standard **error**, so it never corrupts the statusline itself.

## 4. Configure only if asked

The default render needs no config file. If the user asked for more, write
`~/.claude/super-status/config.json` — start with `{ "preset": "full" }` and add
individual keys from the README's full reference on top. A malformed config is
never fatal: the script falls back to defaults and prints one red warning line.

Do not enable `jj.enabled` unless the user uses Jujutsu. Do not set
`api_credit_balance` unless the user gives you the figure — it is a number read
off the Anthropic Console that this project cannot look up.

## 5. Report back

Tell the user, in one message: which route you used, that `doctor.sh` passed,
and what the rendered line looked like. If you changed `settings.json` or
created a config file, say which paths.

## Never

- Never commit anything to the user's repository as part of installing this.
- Never write to `versions/<year>.md` — it is hook-maintained.
- Never edit `.claude-plugin/plugin.json`'s version — `scripts/version-bump.sh`
  owns it (see [RELEASING.md](RELEASING.md)).

</agent_workflow>
