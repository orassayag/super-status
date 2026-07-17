# super-status UI redesign — execution plan

## Goal
Redesign `statusline.sh`'s output from the current dense, 6-8 line, equal-weight
layout into a compact, visually hierarchical layout with consistent bar widths,
shorter labels, and color that carries semantic meaning (not just decoration).

Keep all existing data available. Nothing gets removed — low-priority fields get
deprioritized visually (dimmed, consolidated), not deleted.

## Problems with the current output
1. No visual hierarchy — every label/value pair has equal weight, so nothing
   stands out as "check this first."
2. Duplicated data — `Total Session Time` appears twice; `Tool Calls (9)` is
   broken out twice with overlapping sub-counts (`Commands/Read` then
   `Skills/Code/Read` again).
3. Bars don't align vertically across lines — reset-time strings of varying
   length push bars out of a consistent column.
4. Verbose labels (`Sessions: 5h:`, `Total Session Time:`) cost width without
   adding clarity once paired with a bar/number and consistent position.
5. Color is applied inconsistently — teal/green is used for "value" broadly
   rather than reserved for "healthy/good," with amber/red for warning
   thresholds.
6. The `Activity` line takes a full line to report routine, expected activity.

## Target structure (3-4 lines instead of 6-8)

**Line 1 — Identity (always full color, top priority)**
```
◆ <model> | <repo>:<branch>[/<worktree>] | +N -M | <version>
```
- Model name in accent color (e.g. teal), rest in muted gray.
- `|` separators between each field group, same as the current output.
- `+N -M` (Lines Changes) sits right before the version — this must stay
  visible on line 1, not moved or buried elsewhere. Keep the existing
  behavior of hiding this field entirely when both values are zero (in which
  case line 1 just skips straight from branch/worktree to version).

**Line 2 — Usage bars (Subscription / Sessions / Balance, whichever mode is active)**
```
Sub <bar 10-cell> NN% Reset <short> | 5h <bar> NN% Reset <short> | 1d <bar> NN% Reset <short>
```
- Bars are fixed at **10 cells** (not 20) — still gives 10% resolution and
  saves horizontal space; all bars on all lines use this same width so they
  align in a column when stacked.
- Reset strings shortened: use `4h41m` not `(Reset: 4h41m [00:00])` — drop the
  redundant absolute-time bracket when the relative time is already the
  informative part; keep the absolute date only for the weekly/Nd reset.
- Apply existing color thresholds (green/amber/red) to each bar.
- `|` separates each group (Sub / 5h / 1d / Balance), matching current style.

**Line 3 — Context, cache, cost, tokens (grouped: this is "session cost" info)**
```
Ctx <bar> NN% <used>k/<total>k | Cache NN% | Cost $N.NN | Tok <in>k/<out>k
```
- Cache % and token counts go in muted gray (informational, not actionable).
- Cost stays in its threshold color (existing warm/cool logic if any, else
  neutral until a cost threshold is defined).
- `|` separates each field, same as current output.

**Line 4 — Diagnostics (all muted gray, lowest priority, single line)**
```
LOC ~N.Nk | Session <time> | Thinking <time> | Calls N (Bash N, Read N, Other N)
```
- Consolidate the two existing tool-call breakdowns into one clause here.
- Drop the `Total Session Time` duplication — it only appears once, here.
- `|` separates each field, same as current output.

**Line 5 — Prompt/status line (only if something needs surfacing)**
```
➜ auto mode · N agent[s] · shift+tab to cycle
```
- Keep as-is; lowest-frequency-of-change, so it stays minimal.
- Optional follow-up (not required for v1): only show `Activity:` details when
  something is unusual (a failed tool call, or one running long), instead of
  every session.

## Color rules to implement
- **Green** — value is healthy / well within limits. Use the same teal-green
  accent as the `➜` prompt arrow and the model name on line 1, so "healthy" and
  "identity/accent" read as one consistent color family rather than two
  different greens.
- **Amber** — approaching a threshold (reuse existing thresholds already used
  for Sessions bars; extend the same logic to Context % and Cost if not
  already threshold-based).
- **Red** — at/near limit.
- **Muted gray** — purely informational, not actionable (LOC, thinking time,
  tool tallies, cache %, token counts, version string).
- Never use red/amber for non-actionable fields.

## Implementation steps
1. In `statusline.sh`, add a shared `bar()` helper that always renders a
   **10-cell** bar (refactor from current 20-cell), taking a percentage and
   returning the colored bar string based on threshold rules.
2. Add a shared `dim()` / `muted()` wrapper for the gray-only fields so the
   "informational" color is applied consistently in one place, not
   copy-pasted per field.
3. Rework the line-assembly logic to match the 4-5 line structure above.
   Keep the existing "hide field/line if data missing" behavior — don't print
   empty labels or blank lines.
4. Shorten reset-time formatting: write (or reuse) a helper that renders
   "4h41m" style relative time without the bracketed absolute clock time,
   except for the weekly/Nd reset, which keeps the absolute date.
5. Consolidate the two tool-call breakdown clauses into the single `Calls N
   (...)` clause on the diagnostics line.
6. Update the three README "Output format" examples (Mode 1/2/3) to match the
   new line structure and field names.
7. Update the "What each field means" table in the README to reflect any
   renamed/shortened labels (e.g. `Sub` for Subscription, `Ctx` for Context).

## Testing
- Re-run the existing "Quick test without Claude Code" mock payload command
  from the README after changes and confirm formatted, aligned output.
- Manually test all three backend modes (Anthropic subscription, API key /
  pay-as-you-go, OpenRouter) to confirm each still hides/shows the correct
  line per mode.
- Confirm bar alignment by eye: stack Sub/5h/1d/Ctx bars and verify the `%`
  values line up in the same column across lines at a fixed terminal width.
- Confirm color thresholds fire correctly by testing values near each
  boundary (e.g. subscription usage at 79%/80%/81% if 80% is a threshold).

## Non-goals for this pass
- No new data fields.
- No change to detection logic for backend mode (Anthropic/API key/OpenRouter).
- No change to `doctor.sh`.
