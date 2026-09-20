# Changelog

**The version history lives in [`versions/`](versions/), not here.**

Every commit is auto-versioned by `.git/hooks/post-commit` →
`scripts/version-bump.sh`, which appends a plain-English row to the per-year
ledger `versions/<year>.md` and tags the commit `vX.Y.Z`. That ledger is
written by the hook on every commit, so it cannot fall behind; this file was
hand-written, and did fall three releases behind before anything noticed.

Releases from **2.6.0 onward** are recorded there and published to the
[Releases page](https://github.com/orassayag/super-status/releases) by
`.github/workflows/release.yml`, which reads its notes out of that same ledger
row and fails rather than publishing an empty release.

Everything below is the hand-written history up to 2.5.0, kept because it is
the only record of those releases. It is closed — nothing new is added to it.

## Archive — 2.5.0 and earlier

### 2.5.0 — 22/08/2026

#### Fixed
- **The `Sessions` 5h/`Nd` usage bars now survive `/clear` and a fresh
  session start.** Claude Code only populates `rate_limits` in its stdin JSON
  after the session has made a real API call, so right after `/clear` (or before
  the first turn) both bars vanished until a task kicked off. Since the 5-hour
  and weekly windows are account-global rather than per-session, the last-seen
  values are now cached to disk and restored on a miss — each window
  independently, and only while its cached reset timestamp is still in the
  future, so a window that has since rolled over is never resurrected as a stale
  percentage.

### 2.4.1 — 14/08/2026

#### Fixed
- **The `Sub` bar no longer rolls into a new cycle at the renewal boundary.**
  It previously advanced through calendar months until it found the cycle
  containing "now", so the moment a paid month elapsed it snapped back to `0%`
  for the next cycle — even though renewal isn't automatic (no billing date is
  exposed in the stdin JSON). It now tracks a single cycle anchored to
  `subscription_start_date` and pins at `100%` once that month elapses, staying
  there until `/super-status:subscribe` bumps the date. A full red bar now
  signals "renewal due" instead of a misleading fresh `0%`.

### 2.4.0 — 07/08/2026

#### Fixed
- **The `5h` reset marker now always shows a clock time `(HH:MM)`**, even when
  the reset lands after midnight. The 5-hour window is always under five hours
  away, so a `(dd/MM)` date there was misleading — it read as days away rather
  than hours (e.g. `Reset 4h52m (08/08)` implied a whole day out for a reset
  barely four hours away). The weekly and subscription markers are unchanged:
  they still show `(HH:MM)` for today and `(dd/MM)` for a later day.

#### Added
- **`/super-status:subscribe`** — renewal command that resets
  `subscription_start_date` to today (or a `dd/MM/yyyy` argument) so the `Sub`
  cycle restarts from the renewal day, rewriting the first `CLAUDE.md` that
  declares the key (project-local first, then global) instead of hand-editing.

### 2.3.0 — 25/07/2026

#### Changed
- **Every reset now shows an absolute "when" marker in parens**, not just the
  weekly window. `Sub`, `5h`, and the weekly reset each append a marker after
  their countdown: a clock time `(HH:MM)` when the reset lands on today's date,
  a date `(dd/MM)` when it lands on a later day (e.g. `Reset 2h30m (16:30)`,
  `Reset 3d14h10m (21/07)`). Previously only the weekly reset carried an
  absolute date, formatted `[dd/MM/yyyy]` and shown only when more than a day
  out. The new marker is shorter (no year), consistent across all three resets,
  and answers "when, exactly?" at a glance regardless of how far out the reset
  is.

### 2.2.1 — 18/07/2026

#### Fixed
- **`doctor.sh` now repairs a missing `refreshInterval`** instead of exiting
  "Nothing to do" whenever the `statusLine.command` already pointed at
  super-status. Without `refreshInterval`, the script only re-runs on
  transcript events — so the file-based `Orca:`/`Master:` line froze for the
  entire time the orchestrator session sat blocked on a tool call waiting for
  its agents, which is exactly the window that line exists to cover. Installs
  patched before the 2.1.0 `refreshInterval` recommendation (or hand-edited
  settings) were stuck in that state with no repair path; `doctor.sh` now
  detects the correct-command/missing-interval case and adds the default.

### 2.2.0 — 18/07/2026

#### Changed
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
- **Bar glyph defaults are now `▮`/`▪`** (segmented block bar, was `#`/`-`), and the
  empty portion renders muted gray instead of the usage color — the colored part of
  the bar is the signal, the remainder is just scale. Both glyphs remain configurable
  (`"#"`/`"-"` for ASCII-only terminals).
- **"Healthy"/accent green is a fixed teal-mint (256-color)** instead of the terminal
  theme's palette green, and the warm accent (`Cost` value, todo marker, `×N` counts)
  is orange instead of palette yellow — matching the redesign mock across terminal
  themes rather than inheriting whatever the theme maps ANSI green/yellow to.
- **Reset strings shortened** — bare countdowns (`Reset 2h30m`, not
  `(Reset: 2h30m [12:40])`); only the weekly reset appends its absolute `dd/MM/yyyy`
  date, and only when it's more than a day out.
- **Color now carries semantic meaning only** — green (shared with the model-name
  accent) = healthy, orange = approaching a threshold, red = at/near limit, muted
  gray = informational. `Cache %` is muted instead of threshold-colored (it isn't
  actionable); warning colors never appear on non-actionable fields.
- **`Session`/`Thinking` de-duplicated** — session time appears once, on the
  diagnostics line.

### 2.1.0 — 17/07/2026

#### Added
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

### 2.0.1 — 17/07/2026

#### Fixed
- **`Lines Changes:` reverted to Claude Code's own `cost.total_lines_added`/
  `total_lines_removed` counters**, dropping the workspace-wide git-diff/baseline
  cache introduced alongside it (predates 2.0.0, but the two shipped close
  together and the baseline logic could get stuck showing stale/zero counts
  once its session baseline was established). The tradeoff is the same one
  that logic existed to fix — sub-agent and nested-repo edits won't be
  reflected — but the figure now always matches what Claude Code itself
  reports, updates every render, and has no caching layer to go stale.

### 2.0.0 — 17/07/2026

Large upgrade adopting ideas from [claude-hud](https://github.com/jarrodwatts/claude-hud)
(see `docs/upgrade-plan.md` for the full issue-by-issue plan, I1–I19).

#### Added
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

#### Changed
- **Caches moved out of world-readable `/tmp`** to
  `${XDG_CACHE_HOME:-$HOME/.cache}/super-status/` with `0700` permissions; the
  OpenRouter cache no longer derives its filename from the API key.
  `doctor.sh` removes a legacy `/tmp/super-status` if present. (I7)
- **Single-pass parsing** — one `jq` call over stdin (was ~25), one `jq` call
  for config, and one merged `python3` transcript pass feeding token totals,
  tool buckets, activity, agents, and todos. (I8)
- `doctor.sh` now also checks the executable bit, config validity, cache
  permissions, and preserves `refreshInterval` when re-patching settings.

### 1.x (pre-changelog history)

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
