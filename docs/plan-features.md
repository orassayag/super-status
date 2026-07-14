# super-status — Implementation Plan (v3)

Target file: `statusline.sh` (single bash script, reads stdin JSON from Claude Code, prints labeled lines).

v3 change: Tasks 6/7 are no longer separate new counters (skills, md-files-read) sitting alongside the existing tool-call total — that would double-count data already captured in the line-6 breakdown. Instead, the existing line-6 breakdown (labeled `Tools Stats (N):`, currently split per bash sub-command: `grep: 2 | read: 2 | for: 1 | ls: 1 | sed: 1 | other: 2`) gets **recategorized** into semantic buckets — Skills / Code / Commands / Read / MCP Call / Other — and the line is **renamed to `Tool Calls (N):`**. Same total, more meaningful labels, no new counting logic and no duplicate numbers.

Note: the script currently prints **no** standalone `Tool Calls:` field anywhere — the `Tool Calls: 3` shown on line 5 of the README examples is stale documentation. The internal `tool_count` variable exists only as the Efficiency Grade denominator; Task 4 removes that last consumer, Task 6's renamed line becomes the single visible home of the total, and Task 8 cleans the phantom field out of the README.

Implement in the order listed at the bottom — later tasks depend on data already computed by earlier ones.

---

## Task 1 — Rename "Tokens" → "Total Tokens"

**Where:** wherever the cumulative in/out token field is printed (`Tokens: 890.1k in / 11.6k out`).

**Change:** rename label to `Total Tokens:`. No calculation change.

---

## Task 2 — Annotate Cost as an estimate on subscription mode

**Where:** Line 3 construction:
```bash
if is_num "$cost_usd"; then
  line3="${line3} | ${WHITE}Cost:${RESET} ${YELLOW}\$$(printf "%.2f" "$cost_usd")${RESET}"
fi
```

**Why:** `cost.total_cost_usd` is computed at standard API list rates regardless of backend. On subscription mode this number has no relationship to what's actually billed (flat monthly fee) — it's an "API-equivalent" estimate. On API-key/OpenRouter mode it IS real spend. Label should reflect the difference.

**Change:**
```bash
if is_num "$cost_usd"; then
  cost_label="Cost:"
  [ "$IS_SUBSCRIPTION" -eq 1 ] && cost_label="Cost (est.):"
  line3="${line3} | ${WHITE}${cost_label}${RESET} ${YELLOW}\$$(printf "%.2f" "$cost_usd")${RESET}"
fi
```

**Acceptance criteria:**
- Subscription mode: `Cost (est.): $1.26`.
- API-key / OpenRouter mode: unchanged `Cost: $1.26`.

---

## Task 3 — Rename & simplify "Context Efficiency Grade" → "Cache Vs Tokens"

**Where:** Line 5 construction (grade block for `ctxq_grade`/`cache_ratio`).

**Change:** drop the letter grade entirely, keep only the percentage. Rename label to `Cache Vs Tokens:`. Keep color banding (green ≥75%, orange ≥40%, red below), just keyed off the raw percentage instead of a letter grade.

```bash
total_for_ratio=$(( ${token_input:-0} + ${token_cc:-0} + ${token_cr:-0} ))
cache_ratio=""
if [ "$total_for_ratio" -gt 0 ]; then
  cache_ratio=$(awk "BEGIN{printf \"%.0f\", (${token_cr:-0} / $total_for_ratio) * 100}" 2>/dev/null)
fi
...
if [ -n "$cache_ratio" ]; then
  if   [ "$cache_ratio" -ge 75 ]; then cache_color="$GREEN"
  elif [ "$cache_ratio" -ge 40 ]; then cache_color="$ORANGE"
  else cache_color="$RED"
  fi
  line5="${WHITE}Cache Vs Tokens:${RESET} ${cache_color}${cache_ratio}%${RESET}"
fi
```

**Acceptance criteria:** field reads `Cache Vs Tokens: 42%` — no letter grade.

---

## Task 4 — Fix "Efficiency Grade" denominator (accepted)

**Problem:** current formula is `(lines_added + lines_removed) / total_tool_count`, which counts read-only tools (`grep`, `read`, `ls`, `sed`, etc.) in the denominator, dragging any exploration-heavy session toward F even when tool use was entirely appropriate.

**Change:**
1. Add a counter, `edit_tool_count`, counting only tool_use blocks whose `name` is in an edit-capable set — start with `Edit`, `Write`, `MultiEdit`, `NotebookEdit`, and confirm the exact set against a real transcript file (the same inspection pass used for Task 6 below).
2. Denominator becomes `edit_tool_count` instead of total `tool_count`.
3. If `edit_tool_count == 0` (no edits attempted yet), omit the Efficiency Grade field entirely rather than showing a misleading F(0).

```bash
if [ -n "$edit_tool_count" ] && [ "$edit_tool_count" -gt 0 ]; then
  lines_changed=$(( la + lr ))
  ratio=$(awk "BEGIN{printf \"%.2f\", $lines_changed / $edit_tool_count}" 2>/dev/null)
  eff_score=$(awk "BEGIN{s=$ratio*40; if(s>100) s=100; printf \"%.0f\", s}" 2>/dev/null)
  eff_grade=$(grade_for "$eff_score")
fi
```

**Acceptance criteria:**
- A read-only session (grep/read/ls, no edits) shows no Efficiency Grade field at all.
- The standalone `tool_count` grep block (`statusline.sh:609–632`, plus its `/tmp/super-status/tools-cache` cache) is **deleted** — after this task it has no consumers left. The session's total tool-call count remains visible only as the `(N)` in the renamed `Tool Calls (N):` line from Task 6.

---

## Task 5 — Subscription renewal progress bar, sourced from CLAUDE.md

Anthropic exposes no billing/renewal date anywhere in the stdin JSON. This reads a declared start date directly out of the user's own `CLAUDE.md` — local project file first, global file second.

### 5a. Where the date lives

A line like this, added by the user to their CLAUDE.md (local and/or global):
```
"subscription_start_date": "14/07/2026"
```
Format is **dd/MM/yyyy**, matching every other date this script already prints. Recommend it be placed inside an HTML comment in CLAUDE.md so it doesn't clutter the rendered doc:
```
<!-- "subscription_start_date": "14/07/2026" -->
```
The parser should match the `"subscription_start_date": "..."` pattern regardless of whether it's inside a comment, a code block, or plain text — don't require the comment wrapper, just recommend it in docs.

### 5b. File locations to check, in order

1. **Local:** `CLAUDE.md` at the project root (`git_root`, already resolved earlier in the script).
2. **Global:** `~/.claude/CLAUDE.md` (or wherever Claude Code's documented global memory file actually lives — confirm exact path against current Claude Code docs before finalizing, since this can move between versions).

### 5c. README / repo update needed

Add a new README section (e.g. "Subscription tracking setup") with:
- The exact line to paste into CLAUDE.md, local or global.
- The dd/MM/yyyy format requirement, called out explicitly.
- A short explanation of why it can't be automatic (no billing/renewal date is exposed anywhere in Claude Code's stdin JSON).
- What happens if it's missing or invalid (see 5d/5e below), so the red warning line is self-explanatory the first time someone sees it.

### 5d/5e. Missing / invalid handling

Exact flow (5f), implemented as a bash function, e.g. `resolve_subscription_start_date()`:

```
1. Search local CLAUDE.md for the "subscription_start_date" key.
   - Key found, value is a valid dd/MM/yyyy date  -> use it, stop searching.
   - Key found, value fails validation             -> STATE=invalid, stop searching.
   - Key not found at all (or file doesn't exist)  -> continue to step 2.
2. Search global CLAUDE.md for the same key.
   - Key found, valid    -> use it, stop.
   - Key found, invalid  -> STATE=invalid, stop.
   - Key not found       -> STATE=missing, stop.
```

Validation = both format match (`^[0-3][0-9]/[0-1][0-9]/[0-9]{4}$` as a first-pass regex) AND the date actually parses as a real calendar date (reject `31/02/2026`, `00/01/2026`, etc.). Format-only regex matching is not sufficient; a fast, wrong-looking-right date must still be rejected.

**Do NOT use `date -d "14/07/2026"`** — BSD/macOS `date` has no GNU-style `-d`, and GNU `date` reads slash dates as MM/DD, so it misparses or rejects valid dd/MM input on Linux too. Use the same dual-command BSD/GNU fallback pattern the script already uses for `stat` (`stat -c ... || stat -f ...`):

```bash
# dd/MM/yyyy -> epoch seconds; prints nothing on invalid input
parse_subscription_date() {
    _d="$1"
    _day="${_d%%/*}"; _rest="${_d#*/}"
    _month="${_rest%%/*}"; _year="${_rest#*/}"
    _epoch=$(date -j -f "%d/%m/%Y" "$_d" +%s 2>/dev/null \
          || date -d "${_year}-${_month}-${_day}" +%s 2>/dev/null) || return
    # Round-trip check: BSD strptime silently normalizes 31/02 -> 03/03,
    # so re-format the epoch and require it to match the input exactly.
    # (GNU date rejects 2026-02-31 outright, so the || branch never lies.)
    _back=$(date -j -f "%s" "$_epoch" +%d/%m/%Y 2>/dev/null \
         || date -d "@${_epoch}" +%d/%m/%Y 2>/dev/null)
    [ "$_back" = "$_d" ] && printf '%s' "$_epoch"
}
```

One BSD quirk to handle in the real implementation: `date -j -f` fills unspecified time fields from the current clock, so the epoch drifts by time-of-day between runs. Normalize to midnight (e.g. parse `"$_d 00:00:00"` with format `"%d/%m/%Y %H:%M:%S"`, and GNU-side `date -d "${_year}-${_month}-${_day} 00:00:00"`) so cycle percentages are stable within a day.

**Missing message** (`STATE=missing`), rendered as a **new line, inserted as the very first line of the entire statusline output**, in bold red, pushing the existing Line 1 (Model/Repo/Branch/...) down to become Line 2:
```
SUBSCRIPTION START DATE IS MISSING - ADD IT TO THE CLAUDE.MD: "subscription_start_date": "dd/MM/yyyy"
```

**Invalid message** (`STATE=invalid`), same position, same styling, only the leading phrase changes:
```
SUBSCRIPTION START DATE IS INVALID - ADD IT TO THE CLAUDE.MD: "subscription_start_date": "dd/MM/yyyy"
```

Both use the existing `$RED` constant plus bold (`\033[1m`, or combine into a new `BOLD_RED` constant at the top alongside the other color constants).

This warning line only applies in subscription mode (`IS_SUBSCRIPTION=1`) — API-key/OpenRouter users have no subscription cycle to track, so skip this whole feature for them (no warning, no progress bar).

### 5g. Valid date → progress bar

When a valid `subscription_start_date` is resolved, render a **new standalone line** (own line, not appended to an existing one — insert it directly after the existing Line 1, before the Sessions 5h/7d line):

```
Subscription: 62% [############--------] (Reset: 14d [14/08/2026])
```

Calculation:
1. Parse `subscription_start_date` as epoch.
2. Compute the *current* cycle boundaries by adding calendar months (not fixed 30-day blocks — "14/07 → 14/08" is same day next month, which varies between 28–31 days) to the start date until `cycle_end > now`. **This math is new — there is no existing calendar-month logic in the script to reuse** (the 7-day label at `statusline.sh:507` is plain epoch ceiling-division). Add months by incrementing the month/year fields numerically and re-parsing via the same dual-command `date` pattern as 5d; if the start day doesn't exist in the target month (e.g. 31/01 → February), clamp to that month's last day.
3. `pct_elapsed = (now - cycle_start) * 100 / (cycle_end - cycle_start)`, clamped 0–100.
4. `days_left = ceiling((cycle_end - now) / 86400)`, same rounding convention as the existing 7-day reset label.
5. Render with the existing `make_bar()` helper, same bar width as the other bars.
6. Reuse `usage_color`-style banding on the percentage (green early, orange mid-cycle, red in the final ~2 days before renewal — informational, not a rate-limit warning, but visually still tracks increasing progress).

**Acceptance criteria:**
- Local CLAUDE.md with a valid date takes priority over global.
- Missing key in both files -> bold red missing-message as line 1, nothing else changes.
- Invalid value in local file -> bold red invalid-message as line 1, **global file is not checked** (invalid short-circuits, does not fall through to global).
- Valid date -> no warning line; `Subscription:` line appears standalone, directly after the Model/Repo/Branch line.
- Cycle rolls over correctly at month boundaries with different day-counts (e.g. 31/01 -> 28/02 or 29/02 in a leap year — don't hardcode 30 days).
- Feature is fully inert (no file reads, no warning, no bar) when `IS_SUBSCRIPTION=0`.

---

## Task 6 — Recategorize the `Tools Stats` line into semantic buckets (Skills / Code / Commands / Read / MCP Call / Other) and rename it `Tool Calls`

**Supersedes the earlier idea of separate "Skills Used" and "MD Files Read" counters.** Those numbers are already inside the existing line-6 total — adding parallel counters would double-count the same tool_use blocks under a different name. Instead, relabel the existing breakdown (label `Tools Stats (N):`) into semantic categories, and rename the line to **`Tool Calls (N):`** — the total and the breakdown live in one place under one name.

**This removes the current per-bash-command breakdown.** Today's line doesn't show raw tool names — `bash_category()` (`statusline.sh:682`) deliberately splits every Bash call by its underlying command (`npm`, `git`, `grep`, `sed`, ...), which is why the example above reads `grep: 2 | sed: 1`. All of that collapses into the single `Commands` bucket. This is an intentional simplification: the semantic buckets are the point, and the open-ended command list is what made the line unstable. The README paragraph documenting the bash split (`README.md:178`) is rewritten in Task 8.

**Bucket mapping** (confirm exact tool-name strings against a real transcript file before finalizing — don't assume without checking live data, since exact naming can differ by Claude Code version):

| Bucket     | Tool names that fall into it                                   |
|------------|------------------------------------------------------------------|
| `Skills`   | `Skill`                                                          |
| `Code`     | `Edit`, `Write`, `MultiEdit`, `NotebookEdit`                     |
| `Commands` | `Bash` (shell/command execution)                                 |
| `Read`     | `Read`, `Glob`, `Grep`, `LS` (any read-only/inspection tool)      |
| `MCP Call` | any tool name prefixed `mcp__...` (third-party/MCP tool calls)   |
| `Other`    | anything not matched above (catch-all, same role the current `other` bucket already plays) |

**Implementation:**
1. Reuse the existing transcript-reading/caching pattern already in the script (same `transcript_path`, same mtime-based cache-busting the `Tools Stats` python pass already uses at `statusline.sh:665`), changing the bucketing logic to the six categories above — the `bash_category()` command-splitting goes away.
2. Sum of all bucket counts must equal the `(N)` total in the line's own label (the `total_all` value the python pass already computes) — this is a relabeling of the same data, not a new source of truth. Add this equality as a test/sanity-check when implementing.
3. `Read` bucket subsuming file-type detail (e.g. how many of those reads were `.md` files) is fine to keep as an *internal* detail (e.g. for a future breakdown), but it should not be surfaced as a separate top-line counter — if wanted, it belongs as a sub-annotation on the `Read` bucket itself, e.g. `Read: 4 (2 md)`, not a standalone field.

**New line format**, replacing the current `Tools Stats (N):` line:
```
Tool Calls (9): Skills: 1 | Code: 3 | Commands: 1 | Read: 3 | MCP Call: 0 | Other: 1
```
Same "omit if zero" convention already used everywhere in the script — a bucket with 0 doesn't need to print if that's preferred, though showing all six with zeros is also reasonable here since it's a fixed, small taxonomy (unlike the open-ended tool-name list this replaces). Pick one and apply consistently.

**Acceptance criteria:**
- Line label reads `Tool Calls (N):` — the old `Tools Stats` name appears nowhere in the output.
- Bucket total always equals the `(N)` in the label — no drift, no double-count.
- Every observed tool name in a real transcript maps into exactly one bucket (including `Other` as the guaranteed fallback, so nothing silently disappears).
- Labels read `Skills:`, `Code:`, `Commands:`, `Read:`, `MCP Call:`, `Other:` — no raw tool names, no bash sub-command names.

---

## Combined transcript-parsing note (Tasks 4 and 6)

Tasks 4 (edit-tool count) and 6 (bucketed breakdown) both scan the same `transcript_path` JSONL. Implement **one** parsing pass that produces both the six-bucket breakdown and the `edit_tool_count` needed for Task 4 (in fact `edit_tool_count` should just equal the `Code` bucket from Task 6 — no need to compute it twice), sharing the existing mtime-based cache-invalidation mechanism. Once both tasks land, the older standalone `tool_count` grep pass (`statusline.sh:609–632` and its separate `/tmp/super-status/tools-cache`) has no remaining consumers — delete it, leaving a single transcript-parsing pass. This keeps the script's performance characteristics unchanged (actually slightly improved) despite the added categorization logic.

---

## Task 8 — README.md updates (covers every task above, not just subscription)

The README currently documents exact output examples (`Output format` section, all three backend modes) and a field-by-field reference table (`What each field means`, Lines 1–6). Every task in this plan changes at least one label, one calculated value, or one line's shape — all of it needs to land in the README, not just the subscription feature from Task 5c. Treat this as one checklist to close out before considering the release done:

- **Task 1:** update every `Tokens:` occurrence in the README's example output blocks (all three backend modes) to `Total Tokens:`.
- **Task 2:** update the `Cost:` field's example value and its table description to show the subscription-mode variant `Cost (est.):`, and explain in the table why it differs from API-key mode (estimate vs. real spend).
- **Task 3:** replace `Context Efficiency Grade (A–F): C(71)` in every example block with `Cache Vs Tokens: 71%` (no letter grade), and update its table row to describe it as a plain cache-reuse percentage rather than a graded score.
- **Task 4:** update the `Efficiency Grade (A–F)` table row to note it's now omitted when no edit-capable tool has been used yet in the session (rather than always showing, sometimes as a misleading F(0)).
- **Tasks 4+6 — remove the phantom `Tool Calls:` field:** the README's line-5 examples (`README.md:84`, `:94`, `:105`) and table row (`README.md:170`) show a standalone `Tool Calls: 3` field the script never actually prints. Remove it from every example and from the table — the count now lives only in the renamed line-6 label.
- **Task 6:** replace every `Tools Stats: npm: 34 | pnpm: 10 | ...` example with the new bucketed form, e.g. `Tool Calls (9): Skills: 1 | Code: 3 | Commands: 1 | Read: 3 | MCP Call: 0 | Other: 1`; rename the "Line 6 — Tools Stats" section and its table row to `Tool Calls`; rewrite the bash-command-split explanation (`README.md:178`) to the six-bucket mapping (the same mapping table from Task 6 above can be reused directly); and fix the `python3` prerequisite sentence (`README.md:16`), which names both the old `Tool Calls:` count and the `Tools Stats:` line.
- **Task 5:** the subscription section already speced in 5c — the exact CLAUDE.md line to paste, dd/MM/yyyy format requirement, what the missing/invalid warning lines look like and why, and the new `Subscription:` line's example output in all relevant backend modes (subscription mode only — note explicitly in the README that this section doesn't apply to API-key/OpenRouter modes).

**Acceptance criteria:**
- Every example output block in the README (all three backend modes) reflects the actual current output of the script after all tasks land — no stale field names or example values left over from before this plan.
- Every field-meaning table row matches the field it documents, including the new six-row bucket mapping and the subscription section.
- A fresh reader of the README, with no other context, could correctly predict what today's script prints in every mode without needing to read `statusline.sh` itself.

---

## Suggested order of work

1. Task 1 (trivial, no risk)
2. Task 3 (isolated)
3. Task 2 (isolated)
4. **Inspect a real `transcript_path` JSONL file first** — confirm exact tool names (`Edit`/`Write`/`MultiEdit`/`Skill`/`Read`/`Bash`/`mcp__*`) and exact field names before writing Task 4 or Task 6. This single inspection step de-risks both.
5. Task 6 (bucketed + renamed `Tool Calls` line — do this before Task 4, since Task 4's `edit_tool_count` is just the `Code` bucket from this task)
6. Task 4 (Efficiency Grade denominator, now trivial given Task 6's `Code` bucket already exists)
7. Task 5 (subscription tracking — largest scope: CLAUDE.md parsing in two locations, date validation, month-aware cycle math, new warning-line and new standalone-line rendering paths)
8. Task 8 (README pass — do this last, once every other task's actual final output format is settled, so the docs describe what shipped rather than what was planned)

## Out of scope / explicitly not doing
- No polling of any Anthropic billing endpoint — no such public endpoint exists.
- No separate `subscription.json` config file (superseded by the CLAUDE.md-based approach in Task 5).
- No standalone "Skills Used" or "MD Files Read" counters — folded into the Task 6 bucket breakdown to avoid double-counting against `Tool Calls:`.
