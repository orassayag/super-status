# Rejected — a second interface language

**Date:** 20/09/2026
**Source:** maintenance run `flows/history/maintenance-20-09-26-11-34-00.md`, item
R12, comparing against `jarrodwatts/claude-hud`.

## The idea

Ship a second (and third) interface language the way the compared project does:
English plus Simplified and Traditional Chinese, as a typed module with one file
per locale, a fully translated `README.zh.md`, and a test asserting both READMEs
document the same option keys.

super-status already has the groundwork — a `language` config key, and every
rendered label gathered in one `case` block, so adding a language is genuinely
one branch.

## Why not

The label block is the small half. A real second language means translating the
**whole** options table too — roughly fifty rows today — and the cost is
**ongoing, not one-off**: from then on every new config key needs two entries and
two table rows, on a project where config keys are added most releases.

A translation that drifts is worse than none, because it reads as current while
being wrong. The parity test the comparison recommends is the right guard, but
it only works alongside a complete translation — added on its own it fails on the
first key anyone adds.

Nobody has asked. There is no non-English user of this project on record.

## What was kept instead

The groundwork stays exactly as it is: the `language` key, the single `case`
block, and the README line saying adding a language is one branch. The cost of
keeping the door open is zero; the cost of walking through it is permanent.

## What would change the answer

A non-English user actually asking — an issue, not a hypothetical. At that point
adopt the comparison's full scope in one change set: the labels, the complete
options table, **and** the parity test. Never the labels alone.
