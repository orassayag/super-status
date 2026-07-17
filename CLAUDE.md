# super-status — Project Conventions

## Session handoff

When work in `docs/plan*.md` or `docs/upgrade-plan.md` will span more than one
session, end the entry with a `**Next action:**` line stating one concrete,
resumable step — not a summary of what was done. A future session should be
able to act on that line without re-reading the whole revision history.

Example: `**Next action:** implement I7 (move caches to XDG_CACHE_HOME) — see docs/upgrade-plan.md.`

Skip this on entries that close out the work (e.g. a "Revision N — fix"
entry that fully resolves what it describes needs no next-action line).
