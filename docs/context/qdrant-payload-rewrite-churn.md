# Context Doc: Qdrant payload rewrite churn (per-edit note metadata on every chunk)

_Last verified: 2026-11-05_

## Status
Root cause proven (prod, 2026-11-04/05). Fix 1 pending (branch
`fix/round-fallback-updated-hour`). Fix 2 designed, not built. Tracking issue
Engram#2263. This explains the "cause unproven" tail in
`docs/context/qdrant-payload-put-slowdown-2026-10-26.md`.

## What This Is
Why prod Qdrant CPU is pegged nonstop on a tiny request rate: every edit to a
note without a frontmatter date rewrites the payload of EVERY chunk point of
that note, and Qdrant 1.18+ copies each `set_payload` target into a new
segment, so the optimizer never goes idle.

## Environment
Prod Qdrant is mx1: 0.5 vCPU, 4 GiB RAM, 16 GiB disk
(engram-infra `main/envs/prod/qdrant.tf:65-67`). Qdrant 1.18+.

## Symptom (measured 2026-11-04/05)
- Qdrant CPU pegged nonstop.
- `POST /points/payload`: p99 ~4.7s, 13% of calls 1-5s, mean 285ms.
- Total request rate only ~0.6/s. Load is not the request count; it is the
  per-request write amplification.

## Volume
- Content points written: 29.6k/day (`engram_prom_ex_indexing_points_written_total`).
- Payload rewrites: 517k/day
  (`engram_prom_ex_qdrant_payload_write_ids_sum{caller="refresh"}`);
  412k-980k/day over a week, against a 901k-point collection.
- So we rewrite the payload of roughly half the collection every day while
  adding only ~3% new content.

## Root Cause
1. `PayloadV5.build/2` copies note-level metadata onto every chunk point.
2. Its `up` field falls back to the file mtime / `updated_at` when the note
   has no frontmatter date. That value changes on every edit.
3. So every edit changes `payload_hash`, and `commit_index` refreshes every
   reused point (`lib/engram/indexing.ex` ~L1115:
   `refresh_ids = if payload_hash == note.payload_hash, do: [], else: reused_point_ids`).
4. On Qdrant 1.18+ each `set_payload` target is copied into a new segment;
   the optimizer merges them back forever.
5. `PayloadV6` reuses `PayloadV5.build`, so it keeps the problem.

Cost scales with note SIZE (chunk count) times edit rate, not with what
changed: one keystroke-session on a 700-chunk note rewrites 700 points.

## Proof Query (bastion, `engram_audit_ro`, read-only)
- EmbedNote jobs per note from `oban_jobs` (group by `args->>'note_id'`,
  `args->>'user_id'`, last 24h), multiplied by chunk count per note.
- Chunk counts are behind RLS: `SET app.current_tenant = '<user_id>'` per
  user before counting.
- Result: 95.6% of rewrites come from notes without a frontmatter timestamp.
  81% come from one customer with 5-7 notes of 500-760 chunks each,
  re-indexed 95-209 times/day (the 300s debounce is the ceiling).

## Fixes
1. Round the fallback `up` up to the hour, so edits within an hour keep the
   same `payload_hash` (PR pending, branch `fix/round-fallback-updated-hour`).
   Caps rewrites to at most one per note per hour; still O(chunks) per hour.
2. Immutable chunk index: points hold only `u`, `v`, `n`; Postgres resolves
   every metadata filter. Payload never changes after insert, so metadata
   edits cost zero Qdrant writes. Design: Engram vault
   `50 Engineering/_Superpowers Specs/2026-11-05-immutable-chunk-index-design.md`;
   plan: `docs/superpowers/plans/2026-11-05-immutable-chunk-index-qdrant.md`.

## Rule Learned
Never copy a note-level, per-edit value onto every chunk. Per-operation cost
must not scale with note size. Before adding a payload key, ask: "does this
change when the note is edited?" If yes, it does not belong on chunk points.

## Gotchas
- `rest_responses_max_duration_seconds` is a since-restart MAX. It sat flat
  at 4.1-4.6s all week, which looks like a permanent spike. Use the
  `rest_responses_duration_seconds_bucket` histogram for percentiles.
- Low request rate does not mean low load: check
  `qdrant_payload_write_ids_sum` (ids touched), not request count.
- A version bump to PayloadV6 does not fix this; it shares `PayloadV5.build`.

## Failed Approaches / Dead Ends
- Treating it as a PUT-vs-POST latency problem (the 2026-10-26 doc): the PUT
  mitigation helped but the tail was the segment churn above.
- Resizing Qdrant: the write amplification grows with customer note size, so
  a bigger node only delays it. Fix the payload shape.

## References
- `lib/engram/indexing.ex` (`commit_index`, `payload_hash` refresh ~L1115)
- `lib/engram/indexing/payload_v5.ex`, `lib/engram/indexing/payload_v6.ex`
- `docs/context/qdrant-payload-put-slowdown-2026-10-26.md`
- `docs/context/qdrant-small-node-ingest-oom.md`
- Engram#2263
