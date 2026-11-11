# Context Doc: Search baseline drift from collection-wide IDF

_Last verified: 2026-11-07_

## Status
Known behaviour, not fixed. Per-tenant IDF is tracked in #1622 (security, p2). Drift and tie-break are tracked in #2491.

## Symptom
- Fixed search probes replayed on staging return different top results.
- No code change, and no change to the probed vault.

## Root Cause
The keyword (sparse) leg uses Qdrant's IDF modifier. IDF is computed per COLLECTION, not per tenant. Any other account's writes to the same collection shift every tenant's keyword ranking.

Observed: a 20,878-point synthetic account added to staging after the baseline changed 4 of 17 probes. Deleting that account did NOT restore them. Likely reason (not verified): IDF stats keep counting deleted points until the segments are optimized.

## How It Was Isolated
Everything else was ruled out, leaving IDF by elimination:
- Query embeddings were bit-identical between runs.
- Dense results were exact with and without BQ (binary quantization) rescore.
- Results were stable run to run in vector, keyword and hybrid modes.
- The probed vault had 0 updates and 0 re-embeds in the window.

## How To Run A Valid Before/After Search Comparison
- Record baselines per leg: vector, keyword and hybrid separately.
- Take them immediately before and immediately after the change.
- Add no other account's data to the collection in between.
- Expect low-rank swaps from fused-score ties (#2491). Those are not regressions.

## Gotchas
- CI e2e jobs do NOT shift staging IDF. Each job uses its own collection (`ci_test_<run>_obsidian`, `ci_crdt_<run>`, `ci_headless_<run>`). Only staging accounts write `obsidian_notes`.
- Deleting the data that caused the drift does not undo it (see Root Cause).
- Collection-wide IDF also means one tenant's corpus influences another tenant's ranking, which is why #1622 is filed as a security issue.

## Related
- #1622 per-tenant IDF
- #2491 baseline drift and fused-score tie-break
- `docs/context/index-version-self-heal.md` (what the keyword leg encodes)
