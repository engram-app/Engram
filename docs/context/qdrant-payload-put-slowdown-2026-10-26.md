# Context Doc: Qdrant payload PUT slowdown (2026-10-26)

_Last verified: 2026-10-30_

## Status
PUT mitigated in code (PR 2261, 3d08eab9f). As of 2026-10-30 the remaining
tail is real and inside Qdrant; cause identified with medium-high
confidence (see "2026-10-30 findings"). Decision (2026-10-30): no alert for
now; pursue the code/config fixes under "Options" (pending user approval).

## What This Is
Client metric `op=set_payload` (`engram_prom_ex_qdrant_request_duration_milliseconds`) rose from ~10ms p95 (before 10-17) to 3-4s hourly p95 on `role=worker` by 10-26.

## Symptom and scope
- The `set_payload` op label is ONE instrument (`instrument(:set_payload)` in `lib/engram/vector/qdrant.ex`) covering overwrite_payload, set_payloads, post_payload, delete_payload_keys. The client metric cannot say which call is slow.
- Impact is background-only: EmbedNote p95 0.5-1s -> 3.6s; NoteCommitted flat at 96ms; queue time unchanged.

## Diagnosis method (reuse it)
Use Qdrant's own `rest_responses_duration_seconds` by endpoint + method (`service="qdrant"`, job `prometheus.scrape.qdrant_cluster`). It split PUT from POST on `/collections/{c}/points/payload`:
- PUT: p95 0.27s -> 3.9s, avg 0.10 -> 0.29s (figures from the 10-26 triage, hourly windows; re-query rather than trust, the daily p95 I re-read was 0.7s on 10-25 and 2.9s on 10-26, PUT series first appears 10-25)
- POST: ~12ms in the triage window (hourly p95 since ranges 1-260ms)

Ruled out: optimizer queue (`collection_running_optimizations=0`, `collection_update_queue_length=0` during slow periods).
Correlates: `payload_io_write` rate rose 5-10x after the v3 move (10-24).
Caller: `overwrite_payload` via `refresh_payload` (indexing.ex ~L3737).
RebuildStaleNote backfill peaked 10-24..25 (96k/261k jobs per 6h) but the slowness outlasted it, so the backfill alone does not explain it.

## Fix (PR 2261, 3d08eab9f)
Swap PUT (overwrite) for POST set plus a points-scoped payload delete of known keys (`PayloadKeys.note_keys` + leaked plaintext keys + `note_id`). Telemetry `[:engram,:qdrant,:payload_write]` with a `caller` tag. Dashboard row: engram-infra PR 1635.

## 2026-10-30 findings
Measured (prod, Grafana):
- App side, 7 days of `set_payload`: 27,239 calls, 3.7% over 500 ms, 2.3%
  over 1 s, 0 over 5 s, p50 ~15 ms.
- The app-side slow counts match Qdrant's server-side `POST /points/payload`
  hour by hour, so the time is spent inside Qdrant, not in our client or
  the network.
- Bursty: 0.5-2% over 500 ms most hours, 6-11% in some hours (optimizer
  runs, maintenance sweeps).
- `POST /points/payload` has the worst over-500 ms share of any endpoint
  over 48 h: 0.96%, vs `PUT /points/vectors` 0.64%, upsert 0.10%,
  `/points/payload/delete` 0.07%.
- Correlates (slow share inside vs outside the condition): disk page faults
  over 300/s hold 64% of slow calls (3.4% vs 1.15%); Qdrant CPU near its
  0.5 vCPU cap (4.1% vs 1.45%); optimizer running (3.0% vs 1.5%).

Root cause (deduced, medium-high confidence): Qdrant's copy-on-write move.
A payload or vector update to a point in a non-appendable (optimized)
segment copies the whole point, reading all its on-disk vectors, into the
appendable segment. Hence the page faults and the CPU tie. The follow-up
payload delete on the same ids is fast because those points were just
moved. Our comment in `lib/engram/indexing.ex` (the `refresh_ids` skip in
the commit path, ~L1110) already notes the copy.

Impact: no request path waits on these writes. The payload refresh runs in
`commit_index` (EmbedNote, RebuildStaleNote) and the repath in
`RepathNoteIndex`, all Oban jobs.

Decision (2026-10-30): the user declined an alert on the over-500 ms
share. No alert for now. Pursue these fixes instead, pending user approval:
- Floor the fallback `up` payload timestamp to the day, so a same-day body
  edit leaves the payload unchanged and skips the rewrite (and its
  copy-on-write move).
- Merge the set and the follow-up delete into one `POST /points/batch`, so
  each note costs one request instead of two.

Other options:
- Alert on the over-500 ms share (declined 2026-10-30).
- Full upsert from the vector cache instead of `set_payload` (design change).
- More Qdrant RAM/CPU (costs money).
- `wait=false` (rejected: reopens the marked-indexed-before-visible race).

## Gotchas
- `Engram.PromEx.FixedBucketsTest` pins every histogram's name and `le` boundaries; add new distributions to `@scraped`.
- A 4-partition CI shows one failing test at a time: grep the WHOLE `test/` tree for stale wire-shape stubs (round 2 found a PUT stub in `NoteFieldsTest`).
- Qdrant's server metrics are scraped 3x (one series per Alloy `task`
  label): use `max by` across `task` for counts and rates, or every number
  triples. Quantiles are unaffected.
- Tempo returned no slow Qdrant spans (span naming mismatch, unresolved); do not rely on traces here.
