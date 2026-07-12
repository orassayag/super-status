# super-status — Implementation Plan

> This is a planning document for an implementation agent. **Status: FINAL (Revision 4)** — layout refactor confirmed by the project owner; all other decisions from earlier revisions carry over unchanged unless noted below.

## 0. Project name
`super-status`

## 1. What this is
A single custom Claude Code statusline (`~/.claude/super-status/statusline.sh`) wired into the **user-level** `~/.claude/settings.json`, combining the approved features below from three reference statuslines into one. Output is derived from the JSON Claude Code pipes to the script on stdin (plus light local computation: git, a transcript-count, a last-tool lookup, and a small local cache), rendered as **labeled lines** rather than the original dense symbol-only layout.

## 2. Sources & what was excluded

| Source | Used? | Notes |
|---|---|---|
| `status-line-1.jpeg` / `statusline-specs.html` | ✅ | Most complete reference. LOC count, context bar, API time, version, diff stats, 5h/7d usage with caching+backoff architecture. |
| `status-line-2.jpeg` (token-optimizer) | ✅ | Custom scores (`ContextQ`, `Eff`), `Tools` count. |
| `status-line-3.jpeg` | ❌ **Excluded by owner decision** | The multi-agent rows (Codex/GLM/AGY), `e:XHIGH`, `LOCAL` tag, and the promo banner are not derivable from the Claude Code statusline JSON schema. Confirmed out of scope. Native Claude Code UI chrome (bypass-permissions hint, `← for agents`, clipboard hint) is not part of this project. |

## 3. Approved feature set — Revision 4 layout

The original plan (Revision 1) packed everything into 3 dense, symbol-only lines; Revision 2 replaced that with labeled lines. **Revision 4 keeps the labeled-line structure but rebalances which field lives where**, and adds two fields. Fields are renumbered below (19 total, up from 18) to stay contiguous — see the Revision 4 status note at the bottom for exactly what moved.

### Line 1 — Identity, changes & version
| # | Field | Label | Data origin |
|---|---|---|---|
| 1 | Model display name | `Model:` | `model.display_name` |
| 2 | Project folder name | `Repo:` | last segment of `workspace.project_dir` |
| 3 | Git branch | `Branch:` | `git rev-parse --abbrev-ref HEAD` on git root of `cwd` |
| 4 | Worktree name *(conditional)* | `Worktree:` | `workspace.git_worktree`, omit entirely if absent |
| 5 | Line diff | `Lines Changes:` | **workspace-wide git measurement as of Revision 6** — every git repo found under the workspace root (`workspace.project_dir`, nested client/server repos included) diffed against a per-session baseline recorded at first sight (HEAD sha + pre-existing dirty-line counts), so committed, uncommitted, and untracked changes made by *any* agent since session start are all counted. `cost.total_lines_added/removed` (this session's own tool edits only) remains as the display fallback when no git repo is measurable, and still exclusively feeds the Efficiency Grade. Hidden if both zero |
| 6 | Claude Code version | `Claude Version:` | `version` — **moved here from the old line 6 in Revision 4**, to shorten the bottom line |

### Line 2 — Sessions / Balance (backend-dependent, see §3a)
| # | Field | Label | Data origin |
|---|---|---|---|
| 7 | 5-hour usage % + reset + bar | `Sessions: 5h:` | `rate_limits.five_hour` — reset shown as countdown + `HH:MM` (same-day reset), e.g. `(Reset: 2h30m [12:40])`. Bar is colored to match its own usage threshold (see §6), not a flat color. |
| 8 | Weekly usage % + reset + bar | `Sessions: Nd:` | `rate_limits.seven_day` — reset shown as countdown + `dd/MM/yyyy HH:MM`, e.g. `(Reset: 3d14h10m [11/07/2026 15:00])`; `N` is computed live as days-remaining-until-reset (ceiling), not hardcoded to 7, since the window is rolling (see Revision 3). Bar is colored to match its own usage threshold. |
| 9 | OpenRouter balance bar | `Balance:` | `GET https://openrouter.ai/api/v1/credits` — see §3a, replaces the Sessions line entirely in OpenRouter mode. Bar is colored to match usage, same as fields 7/8. |

### Line 3 — Context, cost & token totals
| # | Field | Label | Data origin |
|---|---|---|---|
| 10 | Context % + 20-char bar + tokens | `Context:` | `context_window.used_percentage` (fallback: computed from token fields), plus `Xk/Yk` token count. Bar is colored to match usage, same as line 2's bars. |
| 11 | Session cost | `Cost:` | `cost.total_cost_usd` — always shown on this line in every backend mode |
| 12 | Cumulative session token totals | `Tokens:` | **new in Revision 4** — shown as `X in / Y out` (k-suffixed). Unlike field 10's token count, this doesn't reset after `/compact` — it's a running total for the whole session. Neither figure is trusted directly from Claude Code's own JSON: `total_input_tokens` stays unreliable early in a session (like `rate_limits`, it's null/absent until at least one real API call completes), and `total_output_tokens` reflects only the *last* exchange rather than a running total. Both are instead derived by the script itself, summing every assistant message's `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` (for `in`) and `output_tokens` (for `out`) out of the transcript JSONL — cached per `session_id`, mtime-gated, same pattern as field 18/19. Empty (and hidden) until Claude Code has made at least one API call this session. |

### Line 4 — Project & timing
| # | Field | Label | Data origin |
|---|---|---|---|
| 13 | LOC count | `Lines of code in project:` | `tokei` on git root, 60s cache |
| 14 | Session duration | `Total Session Time:` | `cost.total_duration_ms` |
| 15 | API inference time | `Total thinking time:` | `cost.total_api_duration_ms` |

### Line 5 — Quality scores & tool usage
| # | Field | Label | Data origin |
|---|---|---|---|
| 16 | Context quality score | `Context Efficiency Grade (A–F):` | **custom heuristic — see §4** |
| 17 | Efficiency score | `Efficiency Grade (A–F):` | **custom heuristic — see §4** |
| 18 | Tool call count | `Tool Calls:` | counted from `transcript_path` JSONL, cached |

### Line 6 — Tools Stats *(replaces the old Timestamp & version line; supersedes the originally planned "Last Tool" field — see Revision 5 note)*
| # | Field | Label | Data origin |
|---|---|---|---|
| 19 | Call counts per tool category, this session | `Tools Stats:` | parsed from `transcript_path` JSONL: every `tool_use` block is counted into a category — `Bash` calls are broken out by their underlying command (`npm`, `git`, `pnpm`, ...) rather than lumped under one `bash` bucket, and all `mcp__*` calls (regardless of server or tool) are folded into a single `mcp` bucket. Ranked by count; only the top `TOOLS_STATS_TOP_N` (5) categories are shown individually, with everything else summed into a trailing `other` bucket (shown even at `0`, so the line's shape stays stable as usage shifts). A leading `(N)` total call count is also shown next to the label. Cached per `session_id`, re-parsed only when the transcript file's mtime changes — same pattern as field 18. Hidden entirely if no transcript is available yet. |

**Field order confirmed by owner. Backend-mode variations below are line-presence swaps within this order, not a reordering.**

> The old `Time:` field (current timestamp via `date`) was **dropped in Revision 4** — it was judged the least useful field on the line it shared with `Claude Version:`, and removing it (while relocating `Claude Version:` to line 1) was the direct way to "shorten the bottom line" per the owner's request. `Claude Version:` itself is retained, just relocated to field 6.

## 3a. Backend detection & mode-specific behavior (unchanged from Revision 1, re-mapped onto the new lines)

Claude Code's stdin JSON doesn't itself declare which backend is in use (Anthropic subscription vs. Anthropic API key vs. OpenRouter vs. z.ai/other). Detection is done by the script at render time:

1. **Anthropic subscription** — `rate_limits.five_hour` / `.seven_day` are present in the stdin JSON. Line 2 renders as `Sessions: 5h: ... | Nd: ...`, where `N` is computed live from `resets_at` rather than hardcoded to 7.
2. **Anthropic API key (pay-as-you-go)** — `rate_limits` absent AND `$ANTHROPIC_BASE_URL` is unset or points at an `anthropic.com` host. Line 2 is **omitted entirely** (no reliable balance source exists — confirmed via Claude Code's own GitHub issue tracker that no public balance endpoint exists for Anthropic API keys). `Cost:` on line 3 is the only usage signal in this mode.
3. **OpenRouter API key** — `$ANTHROPIC_BASE_URL` contains `openrouter.ai`. Line 2 is **replaced** with `Balance: $X.XX / $Y.YY [bar] Z% used`, fetched from OpenRouter's `GET /api/v1/credits` endpoint (`total_credits - total_usage` = remaining; both figures read live, not hardcoded). Requires an OpenRouter API key available to the script via env var (read only, never logged or embedded in the script). Cached 60s to avoid hammering the API on every render.
4. **Other backends (e.g. z.ai)** — treated like mode 2: line 2 omitted. z.ai's API has no public balance-check endpoint, only a dashboard.

### Confirmed sketches (owner-approved, Revision 4)

**Mode 1 — Anthropic subscription (6 lines):**
```
Model: Claude Sonnet 4.6 | Repo: repo | Branch: master | Lines Changes: +45 -12 | Claude Version: v2.1.90
Sessions: 5h: 99% [###################-] (Reset: 2h30m [12:40]) | 3d: 44% [########------------] (Reset: 3d14h10m [11/07/2026 15:00])
Context: 42% [########------------] (46k/200k) | Cost: $1.23 | Tokens: 152.3k in / 45.2k out
Lines of code in project: ~14.2k | Total Session Time: 1h30m | Total thinking time: 1m38s
Context Efficiency Grade (A–F): C(71) | Efficiency Grade (A–F): A(100) | Tool Calls: 3
Tools Stats (53): npm: 34 | pnpm: 10 | git: 6 | edit: 2 | write: 1 | other: 0
```

**Mode 2 — Anthropic API key (pay-as-you-go) (5 lines):**
```
Model: Claude Sonnet 4.6 | Repo: repo | Branch: master | Lines Changes: +45 -12 | Claude Version: v2.1.90
Context: 42% [########------------] (46k/200k) | Cost: $3.42 | Tokens: 152.3k in / 45.2k out
Lines of code in project: ~14.2k | Total Session Time: 1h30m | Total thinking time: 1m38s
Context Efficiency Grade (A–F): C(71) | Efficiency Grade (A–F): A(100) | Tool Calls: 3
Tools Stats (20): read: 12 | edit: 5 | bash: 3 | other: 0
```
*(no Sessions/Balance line — omitted cleanly, no dangling separator)*

**Mode 3 — OpenRouter API key (6 lines):**
```
Model: anthropic/claude-sonnet-4.6 | Repo: repo | Branch: master | Lines Changes: +45 -12 | Claude Version: v2.1.90
Balance: $16.58 / $20.00 [################----] 17% used
Context: 42% [########------------] (46k/200k) | Cost: $3.42 | Tokens: 152.3k in / 45.2k out
Lines of code in project: ~14.2k | Total Session Time: 1h30m | Total thinking time: 1m38s
Context Efficiency Grade (A–F): C(71) | Efficiency Grade (A–F): A(100) | Tool Calls: 3
Tools Stats (59): npm: 34 | pnpm: 10 | mcp: 7 | git: 6 | edit: 2 | other: 2
```

## 4. Custom score definitions (confirmed, unchanged from Revision 1)

- **Context Efficiency Grade (context quality, A–F + 0–100)**: based on cache-reuse ratio — `cache_read_input_tokens / total_tokens`. Higher reuse = more efficient context = higher grade. Bands: A ≥90, B 75–89, C 60–74, D 40–59, F <40.
- **Efficiency Grade (A–F + 0–100)**: based on productive output per tool call — `(lines_added + lines_removed) / tool_call_count`, scaled and bucketed the same A–F way. Low tool-call counts with no lines changed yet default to a neutral/omitted state rather than a misleading score.

## 5. Caching & performance architecture (unchanged, one addition in Revision 4)
- LOC count: 60s cache per git root in `/tmp/super-status/loc-cache/`
- Rate limits: read directly from stdin JSON each render (Claude Code supplies these live); no separate fetch needed
- OpenRouter balance: 60s cache in `/tmp/super-status/openrouter-cache/`, request timeout-bounded so a slow/unreachable API never blocks the render
- Tool count: cached per `session_id` in `/tmp/super-status/tools-cache/`, only re-parsed when transcript file mtime changes
- **Cumulative session token totals (field 12, `Tokens:`)**: cached per `session_id` in `/tmp/super-status/tokentotals-cache/`, same mtime-gated re-parse pattern as the tool count cache above. Despite the field reading `context_window`-shaped data, it is **not** taken directly from the stdin JSON — see the field 12 note in §3 for why both `in` and `out` are instead derived by summing the transcript.
- **Tools Stats (field 19)**: cached per `session_id` in `/tmp/super-status/toolstats-cache/`, same mtime-gated re-parse pattern, so a second parse of the transcript isn't needed on every render
- **Workspace line changes (field 5, Revision 6)**: 10s TTL cache per `session_id` in `/tmp/super-status/workspace-diff-cache/`, plus one `.base` file per repo per session holding that repo's session-start baseline (HEAD sha — or git's empty-tree sha for a repo with no commits yet — and its pre-existing dirty-line counts)
- All external calls (`git`, `tokei`, `curl`) timeout-bounded so the statusline never hangs the UI

## 6. Color system (palette mostly unchanged, bar coloring changed in Revision 4)
Cyan model name, green repo, magenta branch/worktree, grey LOC/version, red/orange/green thresholds for context % and rate-limit % (tighter thresholds for the weekly window than 5-hour), yellow for cost/balance/session-percentages/tool-count, grade-specific color for the two efficiency grades (green A/B, orange C, red D/F). Field **labels** themselves render in white/plain to stay visually distinct from their colored values.

**Revision 4 change:** every progress bar (5h, Nd, Context, Balance) was previously rendered with flat blue brackets regardless of usage level. As of Revision 4, each bar's brackets and fill are colored to match **that bar's own usage-threshold color** (the same green/orange/red logic already used for its percentage number) instead of a flat blue — so a nearly-full context or rate-limit bar is visually red at a glance, not just numerically.

## 7. Hard safety rules (unchanged, extended to the new fields)
- **Never render `null`, `undefined`, or `NaN`.** Every field — label, value, and its separator together — is wrapped in a presence/validity check; if missing or invalid, the whole field is omitted, not replaced with a placeholder. This applies to the new `Tokens:` (field 12) and `Tools Stats:` (field 19) exactly as it does to every pre-existing field.
- All numeric parsing guarded against non-numeric input (`2>/dev/null` pattern from the reference script).
- Worktree field specifically: omitted entirely (not shown as empty) when `workspace.git_worktree` is absent.
- If every field on a given line is missing, the entire line is omitted (no blank line printed) — introduced in Revision 2, and this now also covers line 6 (`Tools Stats:`) on a brand-new session's very first render, before any tool has been called yet.

## 8. Non-interference guarantees (unchanged)
- The script only ever writes to **stdout**. It never modifies `~/.claude/settings.json` beyond the one-time `statusLine` key it's installed under, never touches `permissions`, `hooks`, keybindings, or any other settings key.
- No interaction with Claude Code's input handling — `Ctrl+Tab` / `Shift+Tab` and all native shortcuts are entirely unaffected since those live outside the statusLine render path.
- Render budget: stays well under Claude Code's update throttle so it never introduces visible lag, even with 6 lines instead of 3.

## 9. Plugin-override protection (unchanged)
Since plugins could in theory ship their own `statusLine`/default config, the plan includes:
1. Installing the script to a dedicated path: `~/.claude/super-status/statusline.sh` (not a generic name that's easy to collide with).
2. A small `super-status doctor` check (a one-line script users can re-run) that verifies `~/.claude/settings.json` still points `statusLine.command` at the super-status script, and re-patches it if something else overwrote that key.
3. README documents this as the fix if the statusline ever silently disappears after installing a new plugin.

## 10. Simple install section (for README.md) — unchanged
1. Prerequisites: `jq` and `tokei` installed (one-line install commands per OS). `python3` is also required — it's used for the tool-call count (field 18), the cumulative session token totals (field 12), and the `Tools Stats:` breakdown (field 19).
2. Download/copy `statusline.sh` to `~/.claude/super-status/statusline.sh`, `chmod +x` it.
3. Add one block to `~/.claude/settings.json` (`statusLine.command` pointing at the script) — this makes it global across every project automatically.
4. Restart Claude Code (or open a new session) — statusline appears immediately.
5. One troubleshooting line: how to test the script directly with a mock JSON payload via `echo '...' | bash statusline.sh`.

## 11. README.md structure — unchanged, content updated for Revision 4
- Title + one-line description
- `#FINAL-IMAGE#` placeholder right under the title
- Install section (§10 above)
- Output format section showing the 3 mode sketches (updated for the new 6-line/5-line labeled layout, including the Revision 4 field moves)
- **Field index**: one table per line (6 tables total), what each label means, and where its data comes from
- Backend modes section
- Troubleshooting (plugin-override doctor command, missing-binary fallback behavior, and the two Claude Code timing/availability quirks documented in Revision 4 — see the status note below)
- Note on iterative revisions (this is a living project)

## 12. Out of scope (confirmed, unchanged)
- Multi-CLI dashboard rows (Codex/GLM/AGY usage)
- `e:XHIGH` reasoning-effort tag, `LOCAL`/remote environment tag
- Promo banner
- Anything resembling Claude Code's own native footer chrome (bypass-permissions hint, clipboard hint)

## 13. Date & countdown formatting (updated in Revision 4)
- Every **full date** rendered anywhere in the statusline uses `dd/MM/yyyy`.
- The weekly reset (`Sessions: Nd: ... (Reset: <countdown> [dd/MM/yyyy HH:MM])`) uses this full format for the clock portion, prefixed by a countdown (e.g. `3d14h10m`) — **the countdown prefix is new in Revision 4**; previously this field showed only the clock time, with no time-remaining figure.
- The 5-hour reset (`Sessions: 5h: ... (Reset: <countdown> [HH:MM])`) intentionally omits the date on the clock portion, since that reset always falls within the current day, but **also gained the same countdown prefix in Revision 4** (e.g. `2h30m`), for the same reason as the weekly reset — the reset time alone didn't communicate how long was actually left.
- Countdown format itself: `{d}d{h}h{m}m` with the `d` segment dropped whenever it's zero (so a same-day 5-hour reset always renders as `HhMm`, and only the weekly reset ever shows a `d` segment).
- The old bottom-line `Time:` field (current timestamp, `dd/MM/yyyy HH:MM`) is **removed in Revision 4** — see §3's note on field 19.

---

## Status: FINAL — confirmed (Revision 2)
1. **Layout** — refactored from 3 dense symbol-only lines to 6 labeled lines (5 in API-key mode), one concept per label. Confirmed as written in §3.
2. **Field order** — confirmed as written, all 18 fields retained from Revision 1's 20 (2 dropped: `Compacts` was already removed in Revision 1; the mode-dependent cost *placement/prominence* concept from Revision 1 is dropped in favor of `Cost:` always living on line 3).
3. **Score formulas** (§4) — unchanged, confirmed.
4. **Backend-mode behavior** (§3a) — unchanged logic, remapped onto the new line layout: subscription mode shows the Sessions line; API-key mode (Anthropic/z.ai/other) omits it; OpenRouter mode replaces it with a live Balance line.
5. **Date format** (§13) — confirmed: `dd/MM/yyyy` for all full dates; time-only where a reset falls within the current day.

This plan is ready to hand to an implementation agent.

---

## Status: Revision 3 — dynamic weekly label (post-implementation fix)
The `Sessions:` weekly field was hardcoded as `7d:` under the assumption that the window always resets exactly a week out. Real-world use showed this isn't the case — it's a rolling window (see §3a), so the actual days-remaining can be less than 7. Fixed: the label is now computed live as `Nd:`, where `N` is the ceiling of `(resets_at - now) / 1 day`. All field-table entries, sketches, and prose in §3, §3a, §6, and §13 above reflect this; `7d` no longer appears anywhere in the rendered output.

---

## Status: Revision 4 — bar coloring, reset countdowns, layout rebalance, token totals, tool-usage breakdown (post-implementation fix)
Real-world day-to-day use surfaced five gaps, all addressed together in one pass; §3, §3a, §5, §6, §7, §10, and §13 above reflect all of them:

1. **Progress bars were a flat blue regardless of usage.** Fixed: every bar (5h, Nd, Context, Balance) now renders in the same green/orange/red color already used for its own percentage number, so an at-risk bar is visually obvious without reading the digits. See §6.
2. **Reset times gave a clock/date but no sense of how long was actually left.** Fixed: both the 5-hour and weekly reset fields now show a countdown (`2h30m`, `3d14h10m`) ahead of the existing clock/date. See §3 (fields 7–8) and §13.
3. **The bottom line (`Time:` + `Claude Version:`) was the least informative line on the whole statusline**, and the owner asked for it shortened. Fixed: `Time:` (current timestamp) is dropped entirely, and `Claude Version:` relocates to line 1, right after `Lines Changes:`. See §3, field 6, and the note beneath the Line 6 table.
4. **No way to see cumulative session token usage** — the existing `Context:` field only reflects the *current* context window, which resets after `/compact`, not the whole session. Fixed: a new `Tokens:` field (field 12) on line 3 reads `context_window.total_input_tokens` / `.total_output_tokens` directly from the stdin JSON — no new fetch or cache needed, since Claude Code already supplies these. See §3.
5. **No visibility into what tools were actually being used this session.** Fixed: a new `Tools Stats:` field (field 19) replaces the old timestamp/version line entirely (line 6 is now single-purpose). Rather than surfacing only the single most recent call, it parses the whole session transcript into per-category call counts — `Bash` calls broken out by underlying command (`npm`, `git`, `pnpm`, ...), all `mcp__*` calls folded into one `mcp` bucket, top 5 categories shown individually with the remainder summed into a trailing `other` bucket. This design was settled during implementation (see Revision 5 below) as a more informative alternative to the single-most-recent-call field originally scoped here. Uses the same mtime-gated caching pattern already established for the tool-call count. See §3, field 19, and §5.

Two Claude Code platform behaviors were also confirmed (not statusline bugs, but worth documenting since they were raised during this round):
- `rate_limits` and `context_window.total_input_tokens`/`.total_output_tokens` are both `null`/absent until Claude Code has completed at least one real API call in the session — there is currently no way to see either before that turn. Documented in the README rather than worked around, since no workaround exists.
- A `Sessions: 5h:` usage percentage above 100% (e.g. `108%`) is possible and expected — Anthropic's own usage accounting can briefly overshoot before a session is cut off. The script has never clamped the printed percentage (only the bar's fill width is clamped to 100%), so this was already correct behavior; it's now called out explicitly in the README so it isn't mistaken for a bug.

Field count: 19 total (up from 18), net of dropping `Time:` and adding `Tokens:` and `Tools Stats:`. Every table in §3, every sketch in §3a, and the relevant prose in §6/§13 above already reflect the final state as shipped — see the Revision 5 note below for how field 19 in particular arrived at its final form.

---

## Status: Revision 5 — documentation reconciliation, no code changes

Revision 4 was written and approved around a field-19 design called `Last Tool:` (most-recent tool/MCP call, preferring a URL from that call's input). During implementation this was superseded by `Tools Stats:` — a per-category call-count breakdown for the whole session — as a more useful signal than surfacing only the single most recent call. The shipped `statusline.sh` has only ever implemented `Tools Stats:`; `Last Tool:` never reached the script. This revision brings the plan's prose, field tables, sketches, and caching section in line with what's actually running — no behavior in `statusline.sh` changed as part of this pass. Specifically corrected above:

1. **§3, Line 6 table (field 19)** — relabeled `Last Tool:` → `Tools Stats:`, description rewritten to match the actual per-category/top-N/`other`-bucket/`mcp`-folding logic in the script.
2. **§3a, all three confirmed sketches** — the `Last Tool: ...` line in each mode replaced with a `Tools Stats: ...` line matching real script output (including the leading `(N)` total-call-count prefix).
3. **§5, caching architecture** — the `Last Tool` cache-directory bullet replaced with the `Tools Stats` one (`/tmp/super-status/toolstats-cache/`); a previously-missing bullet added for field 12's own cache (`/tmp/super-status/tokentotals-cache/`), correcting Revision 4's claim that field 12 needed "no new fetch or cache."
4. **§3, field 12 (`Tokens:`)** — description corrected: both `in` and `out` are derived by the script from the transcript (mirroring the caveats already documented for `session_total_input`/`session_total_output` in the script's own comments), not read directly from `context_window.total_input_tokens` / `.total_output_tokens` on the stdin JSON as Revision 4 stated.
5. **§7 and §10** — remaining `Last Tool:` mentions updated to `Tools Stats:`.

README.md has been updated to match on the same points (it had already been written around `Tools Stats:` in its sketches and tables, but still had a handful of stale `Last Tool:` mentions and the same field-12 provenance error — both fixed there too).

---

## Status: Revision 6 — workspace-wide line changes, Tokens: render bug, mode-indicator question (post-implementation fix)

Raised in `docs/plan-issues.md` after real multi-repo `/orca` use; §3 (field 5) and §5 above reflect the final state.

1. **`Lines Changes:` missed everything outside the root repo and everything done by sub-agents.** `cost.total_lines_added/removed` only counts edits made by the *current session's own tools* — work done by `/orca` cmux agents (separate Claude Code sessions) or inside nested git repos scaffolded by a boilerplate (client/ + server/) never appeared. Fixed: field 5 is now measured by the script itself, per Revision 6's field-5 table entry — every git repo under the workspace root is discovered (`find`, depth-capped, `node_modules`/`.venv`/`vendor` pruned) and diffed against a per-session baseline recorded the first time this session sees that repo (HEAD sha + pre-existing dirty-line counts, so a workspace that was already dirty at session start doesn't inflate the figure). Committed, uncommitted, and untracked lines all count, no matter which agent produced them; commits made mid-session stay counted because the diff runs against the session-start sha, not `HEAD`. Known trade-off, accepted: a mid-session `git pull`/branch switch counts incoming lines as session changes. The cost-based figures remain the display fallback and still exclusively feed the Efficiency Grade (which scores *this session's* tool productivity, where other agents' output would be noise). One git subtlety fixed during testing: a repo with no commits yet needs `rev-parse --verify` (plain `rev-parse HEAD` echoes the literal string `HEAD` on an unborn branch, which silently re-baselined the repo on every render); such repos baseline against git's empty-tree object instead.
2. **`Tokens:` (field 12) never rendered — dead code since Revision 4.** The token-totals block gated on `transcript_path`, but the "transcript identifiers" section that resolves `transcript_path`/`session_id` sat *below* it in the file, so the gate always saw an empty value and the field silently never appeared. Fixed by moving the identifier resolution up into the Identity section, ahead of every consumer. No formula change — the transcript-summing logic documented in Revision 5 was correct, just unreachable.
3. **"Sometimes when Claude is thinking I don't see the mode — is it normal?"** Yes — confirmed as native Claude Code behavior, not a statusline issue. The permission-mode indicator (`⏵⏵ auto mode on ...`) is part of Claude Code's own footer chrome (explicitly out of scope per §12), and Claude Code replaces that footer line with its thinking spinner (`✻ ... esc to interrupt`) while generating; the mode indicator returns when the turn ends. Documented in the README's Live updates section rather than worked around, since no workaround exists.
