# Changelog

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
