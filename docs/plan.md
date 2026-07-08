# super-status — Implementation Plan

> This is a planning document for an implementation agent. **Status: FINAL (Revision 2)** — layout refactor confirmed by the project owner; all other decisions from Revision 1 carry over unchanged unless noted below.

## 0. Project name
`super-status`

## 1. What this is
A single custom Claude Code statusline (`~/.claude/super-status/statusline.sh`) wired into the **user-level** `~/.claude/settings.json`, combining the approved features below from three reference statuslines into one. Output is derived from the JSON Claude Code pipes to the script on stdin (plus light local computation: git, a transcript-count, a small local cache), rendered as **labeled lines** rather than the original dense symbol-only layout.

## 2. Sources & what was excluded

| Source | Used? | Notes |
|---|---|---|
| `status-line-1.jpeg` / `statusline-specs.html` | ✅ | Most complete reference. LOC count, context bar, API time, version, diff stats, 5h/7d usage with caching+backoff architecture. |
| `status-line-2.jpeg` (token-optimizer) | ✅ | Custom scores (`ContextQ`, `Eff`), `Tools` count. |
| `status-line-3.jpeg` | ❌ **Excluded by owner decision** | The multi-agent rows (Codex/GLM/AGY), `e:XHIGH`, `LOCAL` tag, and the promo banner are not derivable from the Claude Code statusline JSON schema. Confirmed out of scope. Native Claude Code UI chrome (bypass-permissions hint, `← for agents`, clipboard hint) is not part of this project. |

## 3. Approved feature set — Revision 2 layout

The original plan (Revision 1) packed everything into 3 dense, symbol-only lines. **Revision 2 replaces that with labeled lines**, confirmed by the owner, one concept per label so every value is self-explanatory without a legend. Field *content* and *data origin* are unchanged from Revision 1 — only presentation changed.

### Line 1 — Identity & changes
| # | Field | Label | Data origin |
|---|---|---|---|
| 1 | Model display name | `Model:` | `model.display_name` |
| 2 | Project folder name | `Repo:` | last segment of `workspace.project_dir` |
| 3 | Git branch | `Branch:` | `git rev-parse --abbrev-ref HEAD` on git root of `cwd` |
| 4 | Worktree name *(conditional)* | `Worktree:` | `workspace.git_worktree`, omit entirely if absent |
| 5 | Line diff | `Lines Changes:` | `cost.total_lines_added/removed`, hidden if both zero |

### Line 2 — Sessions / Balance (backend-dependent, see §3a)
| # | Field | Label | Data origin |
|---|---|---|---|
| 6 | 5-hour usage % + reset + bar | `Sessions: 5h:` | `rate_limits.five_hour` — reset shown as `HH:MM` (same-day reset) |
| 7 | Weekly usage % + reset + bar | `Sessions: Nd:` | `rate_limits.seven_day` — reset shown as `dd/MM/yyyy HH:MM`; `N` is computed live as days-remaining-until-reset (ceiling), not hardcoded to 7, since the window is rolling |
| 8 | OpenRouter balance bar | `Balance:` | `GET https://openrouter.ai/api/v1/credits` — see §3a, replaces the Sessions line entirely in OpenRouter mode |

### Line 3 — Context & cost
| # | Field | Label | Data origin |
|---|---|---|---|
| 9 | Context % + 20-char bar + tokens | `Context:` | `context_window.used_percentage` (fallback: computed from token fields), plus `Xk/Yk` token count |
| 10 | Session cost | `Cost:` | `cost.total_cost_usd` — always shown on this line in every backend mode (no more mode-dependent prominence/placement — that was a Revision 1 concept, dropped in Revision 2 for a single consistent layout) |

### Line 4 — Project & timing
| # | Field | Label | Data origin |
|---|---|---|---|
| 11 | LOC count | `Lines of code in project:` | `tokei` on git root, 60s cache |
| 12 | Session duration | `Total Session Time:` | `cost.total_duration_ms` |
| 13 | API inference time | `Total thinking time:` | `cost.total_api_duration_ms` |

### Line 5 — Quality scores & tool usage
| # | Field | Label | Data origin |
|---|---|---|---|
| 14 | Context quality score | `Context Efficiency Grade (A–F):` | **custom heuristic — see §4** |
| 15 | Efficiency score | `Efficiency Grade (A–F):` | **custom heuristic — see §4** |
| 16 | Tool call count | `Tool Calls:` | counted from `transcript_path` JSONL, cached |

### Line 6 — Timestamp & version
| # | Field | Label | Data origin |
|---|---|---|---|
| 17 | Current time | `Time:` | `date`, formatted `dd/MM/yyyy HH:MM` |
| 18 | Claude Code version | `Claude Version:` | `version` |

**Field order confirmed by owner. Backend-mode variations below are line-presence swaps within this order, not a reordering.**

## 3a. Backend detection & mode-specific behavior (unchanged from Revision 1, re-mapped onto the new lines)

Claude Code's stdin JSON doesn't itself declare which backend is in use (Anthropic subscription vs. Anthropic API key vs. OpenRouter vs. z.ai/other). Detection is done by the script at render time:

1. **Anthropic subscription** — `rate_limits.five_hour` / `.seven_day` are present in the stdin JSON. Line 2 renders as `Sessions: 5h: ... | Nd: ...`, where `N` is computed live from `resets_at` rather than hardcoded to 7.
2. **Anthropic API key (pay-as-you-go)** — `rate_limits` absent AND `$ANTHROPIC_BASE_URL` is unset or points at an `anthropic.com` host. Line 2 is **omitted entirely** (no reliable balance source exists — confirmed via Claude Code's own GitHub issue tracker that no public balance endpoint exists for Anthropic API keys). `Cost:` on line 3 is the only usage signal in this mode.
3. **OpenRouter API key** — `$ANTHROPIC_BASE_URL` contains `openrouter.ai`. Line 2 is **replaced** with `Balance: $X.XX / $Y.YY [bar] Z% used`, fetched from OpenRouter's `GET /api/v1/credits` endpoint (`total_credits - total_usage` = remaining; both figures read live, not hardcoded). Requires an OpenRouter API key available to the script via env var (read only, never logged or embedded in the script). Cached 60s to avoid hammering the API on every render.
4. **Other backends (e.g. z.ai)** — treated like mode 2: line 2 omitted. z.ai's API has no public balance-check endpoint, only a dashboard.

### Confirmed sketches (owner-approved, Revision 2)

**Mode 1 — Anthropic subscription (6 lines):**
```
Model: Claude Sonnet 4.6 | Repo: repo | Branch: master | Lines Changes: +45 -12
Sessions: 5h: 23% [####----------------] (Reset: 17:46) | 5d: 41% [########------------] (Reset: 30/06/2026 05:06)
Context: 42% [########------------] (46k/200k) | Cost: $1.23
Lines of code in project: ~14.2k | Total Session Time: 1h30m | Total thinking time: 1m38s
Context Efficiency Grade (A–F): C(71) | Efficiency Grade (A–F): A(100) | Tool Calls: 3
Time: 30/06/2026 18:52 | Claude Version: v2.1.90
```

**Mode 2 — Anthropic API key (pay-as-you-go) (5 lines):**
```
Model: Claude Sonnet 4.6 | Repo: repo | Branch: master | Lines Changes: +45 -12
Context: 42% [########------------] (46k/200k) | Cost: $3.42
Lines of code in project: ~14.2k | Total Session Time: 1h30m | Total thinking time: 1m38s
Context Efficiency Grade (A–F): C(71) | Efficiency Grade (A–F): A(100) | Tool Calls: 3
Time: 30/06/2026 18:52 | Claude Version: v2.1.90
```
*(no Sessions/Balance line — omitted cleanly, no dangling separator)*

**Mode 3 — OpenRouter API key (6 lines):**
```
Model: anthropic/claude-sonnet-4.6 | Repo: repo | Branch: master | Lines Changes: +45 -12
Balance: $16.58 / $20.00 [################----] 17% used
Context: 42% [########------------] (46k/200k) | Cost: $3.42
Lines of code in project: ~14.2k | Total Session Time: 1h30m | Total thinking time: 1m38s
Context Efficiency Grade (A–F): C(71) | Efficiency Grade (A–F): A(100) | Tool Calls: 3
Time: 30/06/2026 18:52 | Claude Version: v2.1.90
```

## 4. Custom score definitions (confirmed, unchanged from Revision 1)

- **Context Efficiency Grade (context quality, A–F + 0–100)**: based on cache-reuse ratio — `cache_read_input_tokens / total_tokens`. Higher reuse = more efficient context = higher grade. Bands: A ≥90, B 75–89, C 60–74, D 40–59, F <40.
- **Efficiency Grade (A–F + 0–100)**: based on productive output per tool call — `(lines_added + lines_removed) / tool_call_count`, scaled and bucketed the same A–F way. Low tool-call counts with no lines changed yet default to a neutral/omitted state rather than a misleading score.

## 5. Caching & performance architecture (unchanged)
- LOC count: 60s cache per git root in `/tmp/super-status/loc-cache/`
- Rate limits: read directly from stdin JSON each render (Claude Code supplies these live); no separate fetch needed
- OpenRouter balance: 60s cache in `/tmp/super-status/openrouter-cache/`, request timeout-bounded so a slow/unreachable API never blocks the render
- Tool count: cached per `session_id`, only re-parsed when transcript file mtime changes
- All external calls (`git`, `tokei`, `curl`) timeout-bounded so the statusline never hangs the UI

## 6. Color system (unchanged palette, applied to the new labeled layout)
Cyan model name, green repo, magenta branch/worktree, blue bar brackets, grey LOC/version/timestamps, red/orange/green thresholds for context % and rate-limit % (tighter thresholds for the weekly window than 5-hour), yellow for cost/balance/session-percentages/tool-count, grade-specific color for the two efficiency grades (green A/B, orange C, red D/F). Field **labels** themselves render in white/plain to stay visually distinct from their colored values.

## 7. Hard safety rules (unchanged)
- **Never render `null`, `undefined`, or `NaN`.** Every field — label, value, and its separator together — is wrapped in a presence/validity check; if missing or invalid, the whole field is omitted, not replaced with a placeholder.
- All numeric parsing guarded against non-numeric input (`2>/dev/null` pattern from the reference script).
- Worktree field specifically: omitted entirely (not shown as empty) when `workspace.git_worktree` is absent.
- **New in Revision 2:** if every field on a given line is missing, the entire line is omitted (no blank line printed). This already applies naturally to line 2 in API-key mode.

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
1. Prerequisites: `jq` and `tokei` installed (one-line install commands per OS).
2. Download/copy `statusline.sh` to `~/.claude/super-status/statusline.sh`, `chmod +x` it.
3. Add one block to `~/.claude/settings.json` (`statusLine.command` pointing at the script) — this makes it global across every project automatically.
4. Restart Claude Code (or open a new session) — statusline appears immediately.
5. One troubleshooting line: how to test the script directly with a mock JSON payload via `echo '...' | bash statusline.sh`.

## 11. README.md structure — unchanged, content updated for Revision 2
- Title + one-line description
- `#FINAL-IMAGE#` placeholder right under the title
- Install section (§10 above)
- Output format section showing the 3 mode sketches (updated for the new 6-line/5-line labeled layout)
- **Field index**: one table per line (6 tables total), what each label means, and where its data comes from
- Backend modes section
- Troubleshooting (plugin-override doctor command, missing-binary fallback behavior)
- Note on iterative revisions (this is a living project)

## 12. Out of scope (confirmed, unchanged)
- Multi-CLI dashboard rows (Codex/GLM/AGY usage)
- `e:XHIGH` reasoning-effort tag, `LOCAL`/remote environment tag
- Promo banner
- Anything resembling Claude Code's own native footer chrome (bypass-permissions hint, clipboard hint)

## 13. Date formatting (new — confirmed by owner)
- Every **full date** rendered anywhere in the statusline uses `dd/MM/yyyy`.
- The weekly reset (`Sessions: Nd: ... (Reset: dd/MM/yyyy HH:MM)`) and the bottom-line timestamp (`Time: dd/MM/yyyy HH:MM`) both use this full format.
- The 5-hour reset (`Sessions: 5h: ... (Reset: HH:MM)`) intentionally omits the date, since that reset always falls within the current day.

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
