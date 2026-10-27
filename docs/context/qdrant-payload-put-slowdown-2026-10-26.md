# Context Doc: Qdrant payload PUT slowdown (2026-10-26)

_Last verified: 2026-10-26_

## Status
Mitigated in code (PR 2261, 3d08eab9f), root cause NOT proven. Verify after the next prod deploy (follow-up issue).

## What This Is
Client metric `op=set_payload` (`engram_prom_ex_qdrant_request_duration_milliseconds`) rose from ~10ms p95 (before 10-17) to 3-4s hourly p95 on `role=worker` by 10-26.

## Symptom and scope
- The `set_payload` op label is ONE instrument (`instrument(:set_payload)` in `lib/engram/vector/qdrant.ex`) covering overwrite_payload, set_payloads, post_payload, delete_payload_keys. The client metric cannot say which call is slow.
- Impact is background-only: EmbedNote p95 0.5-1s -> 3.6s; NoteCommitted flat at 96ms; queue time unchanged.

## Diagnosis method (reuse it)
Use Qdrant's own `rest_responses_duration_seconds` by endpoint + method (`service="qdrant"`, job `prometheus.scrape.qdrant_cluster`). It split PUT from POST on `/collections/{c}/points/payload`:
- PUT: p95 0.27s -> 3.9s, avg 0.10 -> 0.29s
- POST: ~12ms (unchanged)

Ruled out: optimizer queue (`collection_running_optimizations=0`, `collection_update_queue_length=0` during slow periods).
Correlates: `payload_io_write` rate rose 5-10x after the v3 move (10-24).
Caller: `overwrite_payload` via `refresh_payload` (indexing.ex ~L3737).
RebuildStaleNote backfill peaked 10-24..25 (96k/261k jobs per 6h) but the slowness outlasted it, so the backfill alone does not explain it.

## Fix (PR 2261, 3d08eab9f)
Swap PUT (overwrite) for POST set plus a points-scoped payload delete of known keys (`PayloadKeys.note_keys` + leaked plaintext keys + `note_id`). Telemetry `[:engram,:qdrant,:payload_write]` with a `caller` tag. Dashboard row: engram-infra PR 1635.

## Not proven
Why PUT is slow (unverified). Check PUT p95 on the Qdrant-side metric after the next prod deploy.

## Gotchas
- `Engram.PromEx.FixedBucketsTest` pins every histogram's name and `le` boundaries; add new distributions to `@scraped`.
- A 4-partition CI shows one failing test at a time: grep the WHOLE `test/` tree for stale wire-shape stubs (round 2 found a PUT stub in `NoteFieldsTest`).
- Tempo returned no slow Qdrant spans (span naming mismatch, unresolved); do not rely on traces here.
