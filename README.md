# super-status

A combined Claude Code statusline — identity, context usage, session quality, and plan-limit tracking, in labeled lines at the bottom of every session.

![Screenshot](images/demo.png)

## Install

**1. Prerequisites**

```
brew install jq
brew install tokei
```

`jq` is required. `tokei` is optional — the LOC field just won't show without it. `python3` is also required (used to parse the session transcript for the `Tool Calls:` count and the `Tools Stats:` line) — it ships by default on macOS and most Linux distros.

**2. Get the script**

Clone the repo into whichever directory you want it in (this creates a `super-status` folder there):

```
git clone https://github.com/orassayag/super-status.git
```

Navigate into that folder — adjust the path if you cloned it somewhere other than your current directory, or under a different name:

```
cd super-status
```

**3. Install the script**

```
mkdir -p ~/.claude/super-status
cp statusline.sh ~/.claude/super-status/statusline.sh
chmod +x ~/.claude/super-status/statusline.sh
```

**4. Wire it into Claude Code — globally, once**

Add this to `~/.claude/settings.json` (create the file if it doesn't exist):

```
{
  "statusLine": {
    "type": "command",
    "command": "/bin/bash /home/YOUR_USER/.claude/super-status/statusline.sh",
    "refreshInterval": 2
  }
}
```

Replace `/home/YOUR_USER` with your actual home directory. This is the **user-level** settings file, so it applies to every project automatically — no per-project setup needed.

`refreshInterval` (seconds) is optional but recommended — see **Live updates** below for why.

**5. Open a new Claude Code session**

The statusline configuration is read at startup — it won't appear in a session that was already running when you edited `settings.json`. Close your current session and open a new one.

If it still doesn't appear after that, Claude Code may be waiting for workspace trust to be accepted for your working directory. Run `claude` once in that directory and accept the trust prompt when asked, then restart again.

**Quick test without Claude Code:**

```
echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/home/you/myapp"},"context_window":{"used_percentage":25}}' \
  | bash ~/.claude/super-status/statusline.sh
```

If you see formatted, labeled lines with colors, it's working. (Fields that need a live session — like rate limits, token totals, or `Tools Stats:` — won't show with this minimal mock payload; that's expected, see "What each field means" below.)

## Output format

super-status prints labeled lines rather than a dense symbol-only layout, so every value is self-explanatory at a glance. The exact number of lines shown depends on the backend mode (see **Backend modes** below), but the labels and their order are always the same.

**Mode 1 — Anthropic subscription (6 lines):**

```
Model: Claude Sonnet 4.6 | Repo: repo | Branch: master | Lines Changes: +45 -12 | Claude Version: v2.1.90
Sessions: 5h: 99% [###################-] (Reset: 2h30m [12:40]) | 3d: 44% [########------------] (Reset: 3d14h10m [11/07/2026 15:00])
Context: 42% [########------------] (46k/200k) | Cost: $1.23 | Tokens: 152.3k in / 45.2k out
Lines of code in project: ~14.2k | Total Session Time: 1h30m | Total thinking time: 1m38s
Context Efficiency Grade (A–F): C(71) | Efficiency Grade (A–F): A(100) | Tool Calls: 3
Tools Stats: npm: 34 | pnpm: 10 | git: 6 | edit: 2 | write: 1 | other: 0
```

**Mode 2 — Anthropic API key / other pay-as-you-go (5 lines — Sessions line omitted):**

```
Model: Claude Sonnet 4.6 | Repo: repo | Branch: master | Lines Changes: +45 -12 | Claude Version: v2.1.90
Context: 42% [########------------] (46k/200k) | Cost: $3.42 | Tokens: 152.3k in / 45.2k out
Lines of code in project: ~14.2k | Total Session Time: 1h30m | Total thinking time: 1m38s
Context Efficiency Grade (A–F): C(71) | Efficiency Grade (A–F): A(100) | Tool Calls: 3
Tools Stats: read: 12 | edit: 5 | bash: 3 | other: 0
```

**Mode 3 — OpenRouter (6 lines — Sessions line replaced with a live Balance line):**

```
Model: anthropic/claude-sonnet-4.6 | Repo: repo | Branch: master | Lines Changes: +45 -12 | Claude Version: v2.1.90
Balance: $16.58 / $20.00 [################----] 17% used
Context: 42% [########------------] (46k/200k) | Cost: $3.42 | Tokens: 152.3k in / 45.2k out
Lines of code in project: ~14.2k | Total Session Time: 1h30m | Total thinking time: 1m38s
Context Efficiency Grade (A–F): C(71) | Efficiency Grade (A–F): A(100) | Tool Calls: 3
Tools Stats: npm: 34 | pnpm: 10 | mcp: 7 | git: 6 | edit: 2 | other: 2
```

**Colors:** every progress bar (`Sessions: 5h:`, `Sessions: Nd:`, `Context:`, `Balance:`) is colored to match its own usage percentage — green while healthy, orange as it climbs, red once it's at or near the limit — rather than a flat, uninformative color. See the color thresholds under each line's section below.

**Dates:** the 5-hour reset shows a countdown plus `HH:MM` (e.g. `Reset: 2h30m [12:40]`), since that reset always lands within the current day. The weekly reset shows a countdown plus a full `dd/MM/yyyy HH:MM` timestamp (e.g. `Reset: 3d14h10m [11/07/2026 15:00]`), since it can land on a different day.

## Live updates

super-status is a stateless script — it only knows what Claude Code hands it on stdin *at the moment it's invoked*. That has a few visible effects that are Claude Code behavior, not bugs in this script:

- **The statusline disappears during permission prompts, autocomplete, and the help menu.** This is documented, intentional Claude Code behavior — it hides in those moments and reappears once you respond.
- **`Total Session Time` and `Total thinking time` can appear frozen.** By default, Claude Code only re-runs your statusline command after a new assistant message, after `/compact`, when the permission mode changes, or when vim mode toggles — there's no built-in per-second tick. So during a long thinking pause or while waiting on a tool call, both fields hold their last value until the next one of those events fires.
- **Rate-limit data (the `Sessions:` line) and cumulative session token totals (`Tokens:` on the Context line) are both empty until after your first message exchange in a session.** Claude Code only populates `rate_limits` and `context_window.total_input_tokens` / `total_output_tokens` once it's made at least one real API call — there's currently no way to see them before that (this is the single most-requested statusLine feature upstream, [tracked here](https://github.com/anthropics/claude-code/issues/27915)). If you see the `Sessions:` line appear without having typed anything yourself, it's because *something* triggered a background API call (e.g. reloading MCP servers rebuilds the system prompt and does a round-trip) — not because super-status found a way around the limitation.
- **The permission-mode indicator (`⏵⏵ auto mode on ...`) disappears while Claude is thinking.** That line is Claude Code's own footer, not part of super-status — Claude Code temporarily replaces it with the thinking spinner (`✻ ... esc to interrupt`) while a response is being generated, and it comes back when the turn ends. Normal, and nothing a statusline script can influence.
- **A `Sessions: 5h:` percentage above 100% (e.g. `108%`) is expected, not a bug.** Anthropic's own usage accounting can briefly overshoot the limit before Claude Code cuts a session off (e.g. a burst of concurrent or cached requests landing faster than the limit check). super-status prints the percentage exactly as reported rather than silently clamping it to 100 — only the bar's fill width is clamped, so the bar still reads as "full."

To make both time fields update continuously instead of only on those events, add `"refreshInterval": 2` (or any value in seconds, minimum `1`) to the `statusLine` block in `~/.claude/settings.json`, as shown in the install step above. This re-runs the script on a fixed timer in addition to the normal event triggers, so the clock keeps ticking even while Claude is idle or thinking.

## What each field means

### Line 1 — Identity & changes

| Field              | Example             | Meaning                                                                |
| ------------------ | -------------------- | ----------------------------------------------------------------------- |
| `Model:`           | `Claude Sonnet 4.6`  | The model powering the current session                                 |
| `Repo:`            | `repo`               | Current project folder name                                            |
| `Branch:`          | `master`             | Current git branch, resolved from your working directory's git root    |
| `Worktree:`        | `feature-xyz`        | Only appears if this session is running inside a git worktree          |
| `Lines Changes:`   | `+45 -12`             | Lines added/removed across the **whole workspace** since session start — every git repo under the project folder is measured (nested client/server repos included), against a baseline recorded when the session began, so pre-existing uncommitted changes don't count but committed, uncommitted, and untracked changes made during the session all do, even when they were made by sub-agents running in their own sessions (e.g. multi-agent orchestration). Falls back to Claude Code's own per-session counters when no git repo is found. Hidden if both are zero. Refreshed at most every 10s |
| `Claude Version:`  | `v2.1.90`             | Claude Code CLI version                                                |

### Line 2 — Sessions / Balance (backend-dependent — see Backend modes below)

| Field           | Example                                                                              | Meaning                                                                                                                                                                                                        |
| --------------- | ------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Sessions: 5h:` | `99% [###################-] (Reset: 2h30m [12:40])`                                   | % of your rolling 5-hour Anthropic plan limit used, a usage bar colored to match, and time until reset (countdown + clock time)                                                                              |
| `Sessions: Nd:` | `3d: 44% [########------------] (Reset: 3d14h10m [11/07/2026 15:00])`                 | % of your rolling weekly Anthropic plan limit used, a usage bar colored to match, and time until reset (countdown + full date/time). `N` is computed live — the actual number of days from now until the reset (rounded up) — not hardcoded to 7, since this window is rolling and doesn't always land exactly a week out |
| `Balance:`      | `$16.58 / $20.00 [################----] 17% used`                                     | (OpenRouter mode only) live remaining/total credit balance from OpenRouter's `/api/v1/credits` endpoint, bar colored to match usage                                                                          |

Colors: green = healthy, orange = getting close, red = at/near the limit (the weekly window uses tighter thresholds than 5-hour, since a blown weekly quota is more disruptive than a 5-hour one that resets soon). A percentage above 100% can happen (see **Live updates** above) — it's shown as-is rather than clamped, though the bar itself always reads as full.

### Line 3 — Context & cost

| Field      | Example                                 | Meaning                                                                                          |
| ---------- | ---------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `Context:` | `14% [##------------------] (28k/200k)` | How full the context window is, with a usage-colored bar and the raw token count                  |
| `Cost:`    | `$0.14`                                  | Session cost in USD                                                                                |
| `Tokens:`  | `152.3k in / 45.2k out`                  | Cumulative input/output tokens for the **whole session** — unlike the `Context:` figure, this doesn't reset after `/compact`. Both figures are computed by super-status itself, by summing every assistant message's usage fields out of the session transcript (input + cache-creation + cache-read tokens for `in`, output tokens for `out`), rather than trusted straight from Claude Code's own JSON — its `total_input_tokens` is unreliable early in a session and `total_output_tokens` only reflects the *last* exchange rather than a running total. Cached per `session_id`, re-parsed only when the transcript file's mtime changes. Empty until after your first message exchange (see **Live updates**) |

### Line 4 — Project & timing

| Field                       | Example | Meaning                                                                     |
| --------------------------- | ------- | ---------------------------------------------------------------------------- |
| `Lines of code in project:` | `~127`  | Approximate lines of code in the project (via `tokei`, refreshed every 60s) |
| `Total Session Time:`       | `1h30m` | Total session wall-clock time                                              |
| `Total thinking time:`      | `1m38s` | Cumulative time spent waiting on model responses this session              |

### Line 5 — Quality scores & tool usage

| Field                              | Example  | Meaning                                                                                                                                        |
| ----------------------------------- | -------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `Context Efficiency Grade (A–F):`  | `A(99)`  | Context-efficiency grade, based on how much of your context came from cache reuse vs. fresh tokens. Higher = cheaper/more efficient session. |
| `Efficiency Grade (A–F):`          | `A(100)` | Efficiency grade, based on how much code changed per tool call. Higher = more productive tool usage.                                          |
| `Tool Calls:`                       | `3`      | Number of tool calls made so far this session                                                                                                 |

> **Note:** the two efficiency grades are *custom heuristics* built for this project, not official Claude Code metrics. They're a useful relative signal, not an absolute judgment of session quality.

### Line 6 — Tools Stats

| Field           | Example                                          | Meaning                                                                                                                                                                                                                  |
| --------------- | -------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Tools Stats:`  | `npm: 34 \| pnpm: 10 \| git: 6 \| edit: 2 \| write: 1 \| other: 0` | Call counts per tool category this session, parsed from the transcript. `Bash` calls are broken out by their underlying command (`npm`, `git`, `pnpm`, ...) rather than lumped under one `bash` bucket. All `mcp__*` calls, regardless of server or tool, are folded into a single `mcp` bucket. Only the top 5 categories are shown individually, ranked by count; everything else is summed into a trailing `other` bucket (shown even at `0`, so the line's shape stays stable as usage shifts) |

Hidden entirely if no transcript is available yet (e.g. the very first render of a brand-new session).

## Backend modes

super-status detects which backend you're running Claude Code against and adjusts the Sessions/Balance line accordingly. Detection is automatic — no configuration needed beyond your normal Claude Code setup.

### Mode 1 — Anthropic subscription

Detected when Claude Code's `rate_limits` data is present (i.e. you're authenticated against an Anthropic Max/Pro plan). Shows the `Sessions:` line with 5h/Nd usage, colored bars, and reset countdowns as described above.

### Mode 2 — Anthropic API key or other pay-as-you-go backend (e.g. z.ai)

Detected when `rate_limits` is absent. The `Sessions:` line is omitted entirely rather than showing empty or misleading data, because no backend in this mode currently exposes a programmatic balance check (confirmed against Anthropic's own API — there's no public endpoint for pay-as-you-go credit balance — and against z.ai's docs, which only offer a dashboard view). `Cost:` on line 3 remains the primary usage signal available in this mode.

### Mode 3 — OpenRouter

Detected via `$ANTHROPIC_BASE_URL` containing `openrouter.ai`. The `Sessions:` line is replaced with a **live `Balance:` line** pulled from OpenRouter's `/api/v1/credits` endpoint — both the remaining balance and the total are read live (never hardcoded), so top-ups are reflected automatically without any config changes. The bar is colored to match usage, same as the other modes.

**Requires:** an `OPENROUTER_API_KEY` environment variable available to the script (the same key you're already using for Claude Code's `ANTHROPIC_API_KEY`, or a separate one — either works, since it's only used read-only against the `/credits` endpoint, never logged or written anywhere). If this variable isn't set, super-status simply omits the `Balance:` line rather than erroring.

## A note on OpenRouter free models specifically

Everything above covers *paid* backends. If you're routing through OpenRouter to a free-tier model, a couple of things layer on top of Mode 3's behavior:

- **`Cost:` will show `$0.00`**, and the balance bar will barely move — accurate, just not very informative on a free model.
- **`Context Efficiency Grade (A–F)` may sit permanently low.** Most free/non-Anthropic models don't support Anthropic-style prompt caching, so the cache-reuse ratio this score is based on stays near zero — that reflects the backend's capabilities, not the quality of your actual session.

General reliability note: Claude Code is built and tested against Anthropic's first-party API. Routing through OpenRouter — especially to free, non-Anthropic models — isn't officially guaranteed to behave identically, and tool-calling reliability in particular varies a lot by model. If things look inconsistent, that's more likely the backend than the statusline.

## Troubleshooting

**Statusline disappeared after installing a plugin** — some plugins ship their own default config and can overwrite the `statusLine` key. Re-run install step 4 above to re-point it at `~/.claude/super-status/statusline.sh`, or run the included doctor check:

```
bash ~/.claude/super-status/doctor.sh
```

This checks whether `~/.claude/settings.json` still points at the right script and re-patches it if not.

**A field (or a whole line) shows nothing** — that's by design. Every field is hidden — label, value, and separator together — rather than showing `null`/blank placeholders when its data isn't available (e.g. `tokei` not installed, no git repo, no rate-limit data on a non-Anthropic backend, no transcript yet for `Tools Stats:`). If every field on a line is missing, the whole line is omitted rather than printing an empty line.

**`Sessions:` or `Tokens:` shows nothing even though I'm on a subscription plan** — this is expected before your first message exchange in a session; see **Live updates** above. It should appear after your next turn.

**`Sessions: 5h:` shows a percentage over 100%** — expected; see **Live updates** above. Not a bug in this script.

**Nothing shows at all after a fresh install** — Claude Code skips statusLine execution until workspace trust is accepted for the working directory. If you've never run `claude` in that directory before, open a terminal there and run `claude` once to accept the trust prompt, then restart. After that, the statusline will appear in all subsequent sessions.

**Nothing shows at all (trust already accepted)** — test the script directly with the mock payload command in the "Quick test" section of Install (step 5). If that also produces nothing, check `chmod +x` was applied and that the path in `settings.json` is correct and absolute.

**Nothing shows at all and hooks are disabled** — when Claude Code runs with hooks disabled (e.g. via the `--dangerously-skip-permissions` flag or the "Disable hooks" prompt in session), the statusLine is silenced along with all hooks. Re-enable hooks to restore the statusline.

**Statusline disappears during permission prompts, or Session Time / thinking time look stuck** — see [Live updates](#live-updates) above; both are expected Claude Code behavior, and the second is fixable with `refreshInterval`.

**OpenRouter balance line isn't showing** — check that `OPENROUTER_API_KEY` is exported in the environment Claude Code runs in (not just your interactive shell — it needs to be set wherever the statusline script actually executes), and that `$ANTHROPIC_BASE_URL` contains `openrouter.ai`. You can sanity-check the API key works directly: `curl -s https://openrouter.ai/api/v1/credits -H "Authorization: Bearer $OPENROUTER_API_KEY"` should return your balance as JSON.

**`Tools Stats:` isn't showing** — it needs a `transcript_path` from Claude Code pointing at a readable JSONL file with at least one recorded tool call. On a session's very first render, before any tool has been used yet, this line is correctly absent. Also requires `python3` to be on `PATH`.

## Thanks

super-status's `Context Efficiency Grade` and `Efficiency Grade` scores were inspired by the custom scoring concept in [token-optimizer](https://github.com/alexgreensh/token-optimizer). The exact formulas here are our own heuristics (see §4 of `plan.md`), not a port of token-optimizer's internal logic, but the idea of grading a session's context/tool-call efficiency came from that project. Thanks a lot to [@alexgreensh](https://github.com/alexgreensh) for the inspiration.

## A living project

super-status has already gone through one structural refactor — from a dense, symbol-heavy 3-line layout to the labeled, multi-line format above — and will keep iterating as fields get tuned, added, or adjusted based on real day-to-day use. Most recently: usage-colored progress bars across every line, reset countdowns alongside clock/date, cumulative session token totals, the `Time:` field retired in favor of moving `Claude Version:` onto line 1, a new `Tools Stats:` line breaking down call counts per tool category (with `Bash` calls split out by underlying command, and all `mcp__*` calls folded into one bucket), and `Lines Changes:` reworked to measure the whole workspace via git — nested repos and sub-agent work included — instead of only the current session's own edits.
