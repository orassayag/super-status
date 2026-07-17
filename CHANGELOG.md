# Changelog

## 2.2.0 — 18/07/2026

### Changed
- **UI redesign** (see `docs/plan-redesign.md`) — the default output is now a compact,
  visually hierarchical 4-line layout instead of the previous 6–8 equal-weight labeled
  lines. All data is preserved; low-priority fields are visually deprioritized (muted,
  consolidated), not removed:
  - **Line 1 — identity:** `◆ <model> | repo:branch[/worktree] | +N -M | vX.Y.Z`.
    Model in the accent color; verbose labels (`Model:`, `Repo:`, `Branch:`,
    `Lines Changes:`, `Claude Version:`) dropped.
  - **Line 2 — usage bars:** `Sub` / `5h` / `Nd` / `Bal` share one line, each as
    `label bar % reset`.
  - **Line 3 — session cost:** `Ctx` bar, `Cache %`, `Cost`, `Tok in/out`.
  - **Line 4 — diagnostics:** all muted gray — `LOC`, `Session`, `Thinking`, `Eff`,
    and one consolidated `Calls N (Bash n, Read n, ...)` clause (the two previous
    overlapping tool-call breakdowns merged; only non-zero buckets are spelled out).
- **Bars are 10 cells (was 20), bracket-less, and bar-first** (`bar NN%` instead of
  `NN% [bar]`) — every bar on every line is the same width, so stacked bars and their
  `%` values align in a column. `bar_width` in config still overrides.
- **Reset strings shortened** — bare countdowns (`Reset 2h30m`, not
  `(Reset: 2h30m [12:40])`); only the weekly reset appends its absolute `dd/MM/yyyy`
  date, and only when it's more than a day out.
- **Color now carries semantic meaning only** — green (shared with the model-name
  accent) = healthy, orange = approaching a threshold, red = at/near limit, muted
  gray = informational. `Cache %` is muted instead of threshold-colored (it isn't
  actionable); warning colors never appear on non-actionable fields.
- **`Session`/`Thinking` de-duplicated** — session time appears once, on the
  diagnostics line.

## 2.1.0 — 17/07/2026

### Added
- **`Orca:` / `Master:` line** — live run state for the
  [`/orca` and `/master`](https://github.com/orassayag/agentic-project-workflow) parallel/sequential
  execution workflows, read directly off the on-disk files those tools already treat as their own
  source of run state (`.claude/status.md`, `docs/status/stage-plan.md`) rather than the session
  transcript. This is the one signal this script has of wave agents at all — they run as separate
  cmux-worktree processes with their own transcript, invisible to the orchestrating session's stdin
  JSON — and because it's file-based rather than transcript-based, it keeps updating (with
  `refreshInterval` set) even while the orchestrator session is idle, blocked on a tool call waiting
  for the wave. `Orca:` buckets task rows by status and hides once every row is `REBASED & MERGED`;
  `Master:` shows the open stage with elapsed time since spawn and hides once every stage is
  `COMMITTED`. Off by default; enabled via `"preset": "full"`/`"essential"` or
  `"display": {"orchestrator": true}`.

## 2.0.1 — 17/07/2026

### Fixed
- **`Lines Changes:` reverted to Claude Code's own `cost.total_lines_added`/
  `total_lines_removed` counters**, dropping the workspace-wide git-diff/baseline
  cache introduced alongside it (predates 2.0.0, but the two shipped close
  together and the baseline logic could get stuck showing stale/zero counts
  once its session baseline was established). The tradeoff is the same one
  that logic existed to fix — sub-agent and nested-repo edits won't be
  reflected — but the figure now always matches what Claude Code itself
  reports, updates every render, and has no caching layer to go stale.

## 2.0.0 — 17/07/2026

Large upgrade adopting ideas from [claude-hud](https://github.com/jarrodwatts/claude-hud)
(see `docs/upgrade-plan.md` for the full issue-by-issue plan, I1–I19).

### Added
- **Config file** `~/.claude/super-status/config.json` — per-field show/hide
  toggles, presets (`full` / `essential` / `minimal`), bar width and glyphs,
  per-element color overrides (named / 256 / hex), color thresholds, and
  custom line layouts. Missing file = previous behavior exactly; malformed
  JSON falls back to defaults with a one-line warning. (I5, I10, I14)
- **Live tool-activity line** — the currently running tool (`◐ Edit: auth.ts`)
  plus recent completed tool calls grouped with counts (`✓ Read ×3`). (I1)
- **Subagent status line** — in-flight agents with type, model, task
  description, and elapsed time. (I2)
- **Todo progress line** — current in-progress todo plus `(completed/total)`. (I3)
- **Git status enrichment** — dirty `*` marker, `↑ahead ↓behind` vs. upstream
  (with configurable warning/critical thresholds on the unpushed count), and
  `!modified +staged ?untracked` file counts. (I4)
- **Plugin packaging + one-command install** — `.claude-plugin/` manifest,
  `/super-status:setup` command, and `install.sh` (no more hand-editing
  settings.json with placeholder paths). (I6)
- **Context value formats** — `context_value: percent | tokens | remaining | both`,
  with `remaining` using Claude Code's own `remaining_percentage` when present. (I9)
- **Compact layout** — `layout: expanded | compact` collapses the default
  multi-line output down to 3 lines for small terminal panes; `lines` in
  config.json can also override either preset entirely to reorder or merge
  segments onto shared lines. (I14)
- **Width-aware truncation** — lines are cut to `$COLUMNS` / config
  `max_width` with a trailing `…`, ANSI-escape- and UTF-8-aware. (I11)
- **`path_levels`** — show 1–5 trailing path components in the `Repo:` field. (I12)
- **Kill switch** — `SUPER_STATUS_DISABLE=1` renders nothing for a session. (I13)
- **Provider badge** — `Model: … [OpenRouter]` / `[z.ai]` / any non-Anthropic
  `ANTHROPIC_BASE_URL` host. (I17)
- **Centralized labels** — every rendered string lives in one language-keyed
  block (`language` config key; only `en` ships). (I18)
- **Test suite + CI** — bats-core tests and shellcheck on macOS + Ubuntu via
  GitHub Actions. (I15)
- LICENSE (MIT), this CHANGELOG, SECURITY.md, and a README Requirements
  section covering supported platforms. (I16, I19)

### Changed
- **Caches moved out of world-readable `/tmp`** to
  `${XDG_CACHE_HOME:-$HOME/.cache}/super-status/` with `0700` permissions; the
  OpenRouter cache no longer derives its filename from the API key.
  `doctor.sh` removes a legacy `/tmp/super-status` if present. (I7)
- **Single-pass parsing** — one `jq` call over stdin (was ~25), one `jq` call
  for config, and one merged `python3` transcript pass feeding token totals,
  tool buckets, activity, agents, and todos. (I8)
- `doctor.sh` now also checks the executable bit, config validity, cache
  permissions, and preserves `refreshInterval` when re-patching settings.

## 1.x (pre-changelog history)

- Structural refactor from a dense, symbol-heavy 3-line layout to the labeled
  multi-line format.
- `Subscription:` billing-cycle bar sourced from a user-declared start date in
  CLAUDE.md.
- Per-command `Tools Stats:` breakdown replaced by the stable six-bucket
  `Tool Calls (N):` line (Skills / Code / Commands / Read / MCP Call / Other).
- Letter-graded context score simplified to a plain `Cache Vs Tokens:`
  percentage.
- `Efficiency Grade` re-based on edit-capable tool calls only (and hidden
  during pure exploration).
- `Cost:` relabeled `Cost (est.):` on subscription mode where it's an estimate
  rather than real spend; `Tokens:` renamed `Total Tokens:`.
