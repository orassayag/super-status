# super-status

A combined Claude Code statusline — identity, context usage, session quality, and plan-limit tracking, in labeled lines at the bottom of every session.

![Screenshot](images/demo.png)

## Install

**1. Prerequisites**

```bash
brew install jq
brew install tokei
```

`jq` is required. `tokei` is optional — the LOC field just won't show without it.

**2. Get the script**

Clone the repo into whichever directory you want it in (this creates a `super-status` folder there):

```bash
git clone https://github.com/orassayag/super-status.git
```

Navigate into that folder — adjust the path if you cloned it somewhere other than your current directory, or under a different name:

```bash
cd super-status
```

**3. Install the script**

```bash
mkdir -p ~/.claude/super-status
cp statusline.sh ~/.claude/super-status/statusline.sh
chmod +x ~/.claude/super-status/statusline.sh
```

**4. Wire it into Claude Code — globally, once**

Add this to `~/.claude/settings.json` (create the file if it doesn't exist):

```json
{
  "statusLine": {
    "type": "command",
    "command": "/bin/bash /home/YOUR_USER/.claude/super-status/statusline.sh"
  }
}
```

Replace `/home/YOUR_USER` with your actual home directory. This is the **user-level** settings file, so it applies to every project automatically — no per-project setup needed.

**5. Open a new Claude Code session**

The statusline configuration is read at startup — it won't appear in a session that was already running when you edited `settings.json`. Close your current session and open a new one.

If it still doesn't appear after that, Claude Code may be waiting for workspace trust to be accepted for your working directory. Run `claude` once in that directory and accept the trust prompt when asked, then restart again.

**Quick test without Claude Code:**

```bash
echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/home/you/myapp"},"context_window":{"used_percentage":25}}' \
  | bash ~/.claude/super-status/statusline.sh
```

If you see formatted, labeled lines with colors, it's working.

## Output format

super-status prints labeled lines rather than a dense symbol-only layout, so every value is self-explanatory at a glance. The exact number of lines shown depends on the backend mode (see **Backend modes** below), but the labels and their order are always the same.

**Mode 1 — Anthropic subscription (6 lines):**
```
Model: Claude Sonnet 4.6 | Repo: repo | Branch: master | Lines Changes: +45 -12
Sessions: 5h: 23% [####----------------] (Reset: 17:46) | 7d: 41% [########------------] (Reset: 30/06/2026 05:06)
Context: 42% [########------------] (46k/200k) | Cost: $1.23
Lines of code in project: ~14.2k | Total Session Time: 1h30m | Total thinking time: 1m38s
Context Efficiency Grade (A–F): C(71) | Efficiency grade (A-F): A(100) | Tool Calls: 3
Time: 30/06/2026 18:52 | Claude Version: v2.1.90
```

**Mode 2 — Anthropic API key / other pay-as-you-go (5 lines — Sessions line omitted):**
```
Model: Claude Sonnet 4.6 | Repo: repo | Branch: master | Lines Changes: +45 -12
Context: 42% [########------------] (46k/200k) | Cost: $3.42
Lines of code in project: ~14.2k | Total Session Time: 1h30m | Total thinking time: 1m38s
Context Efficiency Grade (A–F): C(71) | Efficiency grade (A-F): A(100) | Tool Calls: 3
Time: 30/06/2026 18:52 | Claude Version: v2.1.90
```

**Mode 3 — OpenRouter (6 lines — Sessions line replaced with a live Balance line):**
```
Model: anthropic/claude-sonnet-4.6 | Repo: repo | Branch: master | Lines Changes: +45 -12
Balance: $16.58 / $20.00 [################----] 17% used
Context: 42% [########------------] (46k/200k) | Cost: $3.42
Lines of code in project: ~14.2k | Total Session Time: 1h30m | Total thinking time: 1m38s
Context Efficiency Grade (A–F): C(71) | Efficiency grade (A-F): A(100) | Tool Calls: 3
Time: 30/06/2026 18:52 | Claude Version: v2.1.90
```

**Dates:** every full date super-status prints (the 7-day reset, and the `Time:` field) uses `dd/MM/yyyy`. The 5-hour reset only ever shows `HH:MM`, since that reset always lands within the current day.

## What each field means

### Line 1 — Identity & changes
| Field | Example | Meaning |
|---|---|---|
| `Model:` | `Claude Sonnet 4.6` | The model powering the current session |
| `Repo:` | `repo` | Current project folder name |
| `Branch:` | `master` | Current git branch, resolved from your working directory's git root |
| `Worktree:` | `feature-xyz` | Only appears if this session is running inside a git worktree |
| `Lines Changes:` | `+45 -12` | Lines added/removed this session (hidden if both are zero) |

### Line 2 — Sessions / Balance (backend-dependent — see Backend modes below)
| Field | Example | Meaning |
|---|---|---|
| `Sessions: 5h:` | `12% [##------------------] (Reset: 14:00)` | % of your rolling 5-hour Anthropic plan limit used, a usage bar, and when it resets |
| `Sessions: 7d:` | `12% [##------------------] (Reset: 14/07/2026 15:00)` | % of your rolling 7-day Anthropic plan limit used, a usage bar, and when it resets |
| `Balance:` | `$16.58 / $20.00 [################----] 17% used` | (OpenRouter mode only) live remaining/total credit balance from OpenRouter's `/api/v1/credits` endpoint |

Colors: green = healthy, orange = getting close, red = at/near the limit (7-day uses tighter thresholds than 5-hour, since a blown weekly quota is more disruptive than a 5-hour one that resets soon).

### Line 3 — Context & cost
| Field | Example | Meaning |
|---|---|---|
| `Context:` | `14% [##------------------] (28k/200k)` | How full the context window is, with the raw token count |
| `Cost:` | `$0.14` | Session cost in USD |

### Line 4 — Project & timing
| Field | Example | Meaning |
|---|---|---|
| `Lines of code in project:` | `~127` | Approximate lines of code in the project (via `tokei`, refreshed every 60s) |
| `Total Session Time:` | `1h30m` | Total session wall-clock time |
| `Total thinking time:` | `1m38s` | Cumulative time spent waiting on model responses this session |

### Line 5 — Quality scores & tool usage
| Field | Example | Meaning |
|---|---|---|
| `Context Efficiency Grade (A–F):` | `A(99)` | Context-efficiency grade, based on how much of your context came from cache reuse vs. fresh tokens. Higher = cheaper/more efficient session. |
| `Efficiency grade (A-F):` | `A(100)` | Efficiency grade, based on how much code changed per tool call. Higher = more productive tool usage. |
| `Tool Calls:` | `3` | Number of tool calls made so far this session |

> **Note:** the two efficiency grades are *custom heuristics* built for this project, not official Claude Code metrics. They're a useful relative signal, not an absolute judgment of session quality.

### Line 6 — Timestamp & version
| Field | Example | Meaning |
|---|---|---|
| `Time:` | `07/07/2026 10:36` | Current local date and time (`dd/MM/yyyy HH:MM`) |
| `Claude Version:` | `v2.1.90` | Claude Code CLI version |

## Backend modes

super-status detects which backend you're running Claude Code against and adjusts the Sessions/Balance line accordingly. Detection is automatic — no configuration needed beyond your normal Claude Code setup.

### Mode 1 — Anthropic subscription (unchanged)
Detected when Claude Code's `rate_limits` data is present (i.e. you're authenticated against an Anthropic Max/Pro plan). Shows the `Sessions:` line with 5h/7d usage as described above.

### Mode 2 — Anthropic API key or other pay-as-you-go backend (e.g. z.ai)
Detected when `rate_limits` is absent. The `Sessions:` line is omitted entirely rather than showing empty or misleading data, because no backend in this mode currently exposes a programmatic balance check (confirmed against Anthropic's own API — there's no public endpoint for pay-as-you-go credit balance — and against z.ai's docs, which only offer a dashboard view). `Cost:` on line 3 remains the only usage signal available in this mode.

### Mode 3 — OpenRouter
Detected via `$ANTHROPIC_BASE_URL` containing `openrouter.ai`. The `Sessions:` line is replaced with a **live `Balance:` line** pulled from OpenRouter's `/api/v1/credits` endpoint — both the remaining balance and the total are read live (never hardcoded), so top-ups are reflected automatically without any config changes.

**Requires:** an `OPENROUTER_API_KEY` environment variable available to the script (the same key you're already using for Claude Code's `ANTHROPIC_API_KEY`, or a separate one — either works, since it's only used read-only against the `/credits` endpoint, never logged or written anywhere). If this variable isn't set, super-status simply omits the `Balance:` line rather than erroring.

## A note on OpenRouter free models specifically

Everything above covers *paid* backends. If you're routing through OpenRouter to a free-tier model, a couple of things layer on top of Mode 3's behavior:

- **`Cost:` will show `$0.00`**, and the balance bar will barely move — accurate, just not very informative on a free model.
- **`Context Efficiency Grade (A–F)` may sit permanently low.** Most free/non-Anthropic models don't support Anthropic-style prompt caching, so the cache-reuse ratio this score is based on stays near zero — that reflects the backend's capabilities, not the quality of your actual session.

General reliability note: Claude Code is built and tested against Anthropic's first-party API. Routing through OpenRouter — especially to free, non-Anthropic models — isn't officially guaranteed to behave identically, and tool-calling reliability in particular varies a lot by model. If things look inconsistent, that's more likely the backend than the statusline.

## Troubleshooting

**Statusline disappeared after installing a plugin** — some plugins ship their own default config and can overwrite the `statusLine` key. Re-run install step 4 above to re-point it at `~/.claude/super-status/statusline.sh`, or run the included doctor check:

```bash
bash ~/.claude/super-status/doctor.sh
```

This checks whether `~/.claude/settings.json` still points at the right script and re-patches it if not.

**A field (or a whole line) shows nothing** — that's by design. Every field is hidden — label, value, and separator together — rather than showing `null`/blank placeholders when its data isn't available (e.g. `tokei` not installed, no git repo, no rate-limit data on a non-Anthropic backend). If every field on a line is missing, the whole line is omitted rather than printing an empty line.

**Nothing shows at all after a fresh install** — Claude Code skips statusLine execution until workspace trust is accepted for the working directory. If you've never run `claude` in that directory before, open a terminal there and run `claude` once to accept the trust prompt, then restart. After that, the statusline will appear in all subsequent sessions.

**Nothing shows at all (trust already accepted)** — test the script directly with the mock payload command in the "Quick test" section of Install (step 5). If that also produces nothing, check `chmod +x` was applied and that the path in `settings.json` is correct and absolute.

**Nothing shows at all and hooks are disabled** — when Claude Code runs with hooks disabled (e.g. via the `--dangerously-skip-permissions` flag or the "Disable hooks" prompt in session), the statusLine is silenced along with all hooks. Re-enable hooks to restore the statusline.

**OpenRouter balance line isn't showing** — check that `OPENROUTER_API_KEY` is exported in the environment Claude Code runs in (not just your interactive shell — it needs to be set wherever the statusline script actually executes), and that `$ANTHROPIC_BASE_URL` contains `openrouter.ai`. You can sanity-check the API key works directly: `curl -s https://openrouter.ai/api/v1/credits -H "Authorization: Bearer $OPENROUTER_API_KEY"` should return your balance as JSON.

## Thanks

super-status's `Context Efficiency Grade` and `Efficiency grade` scores were inspired by the custom scoring concept in [token-optimizer](https://github.com/alexgreensh/token-optimizer). The exact formulas here are our own heuristics (see §4 of `plan.md`), not a port of token-optimizer's internal logic, but the idea of grading a session's context/tool-call efficiency came from that project. Thanks a lot to [@alexgreensh](https://github.com/alexgreensh) for the inspiration.

## A living project

super-status has already gone through one structural refactor — from a dense, symbol-heavy 3-line layout to the labeled, multi-line format above — and will keep iterating as fields get tuned, added, or adjusted based on real day-to-day use.
