# Context Doc: Measuring CRDT doc bloat — the traps in the numbers

_Last verified: 2026-09-18_

## Status

Working. Telemetry shipped for #1706 (`checkpoint_doc` histograms +
`state_sweep` gauges). The flatten-gate rework it feeds, **#1707, is not done** —
these numbers exist so that gate is tuned against measurement rather than
against a guess.

## What This Is

`crdt_state_ciphertext` is the largest column in the database and it grows with
edit count, not with note length. The bloat ratio `state_bytes / content_bytes`
is how far the encoded Yjs doc runs ahead of the text it encodes. This doc is
about the four ways that number lies to you, and the cron detail that keeps the
sweep honest.

Code:

- `lib/engram/notes/crdt_bloat.ex` — the eligibility floor
- `lib/engram/notes/crdt_checkpoint.ex` — per-checkpoint (biased) sample
- `lib/engram/workers/crdt_bloat_sweep.ex` — whole-population sweep, every 6h
- `lib/engram/prom_ex/crdt.ex` — both sets of metrics
- `test/engram/oban_cron_test.exs`, `test/engram/workers/crdt_bloat_sweep_test.exs`

## Trap 1 — near-empty notes make the ratio lie

Measured on staging 2026-09-18 across 5,277 notes holding CRDT state:

| population | p50 | p90 | p99 | max | over 5x |
|---|---|---|---|---|---|
| unfiltered | 1.07 | 2.00 | 2.00 | 12.75 | 1 |
| content >= 100 bytes (3,345 notes) | 1.02 | 1.15 | 1.62 | 1.77 | 0 |

1,932 notes hold under 100 bytes, most of them a **2-byte Yjs doc**. They pin
p90 and p99 to exactly `2.0`. Read naively that says "10% of notes carry 2x
bloat"; what it actually says is "37% of notes are empty". A flatten gate tuned
against the unfiltered column would be tuned against empty files.

The fix, in three places:

- `Engram.Notes.CrdtBloat.min_content_bytes/0` = **100 bytes**. Deliberately
  generous — real notes have a p50 around 1.1 KB, so it excludes empties and
  stubs without reaching anything a user would call a note.
- `CrdtCheckpoint.emit_doc_stats/3` **omits** the `:bloat_ratio` measurement key
  below the floor rather than zeroing it. `Telemetry.Metrics` skips a metric
  whose measurement key is absent, so the ratio histogram takes no sample while
  the byte histograms still take one. A zero would drag the distribution down
  exactly as the empties dragged it up. Consequence: `bloat_ratio`'s `_count` is
  **lower than** the `state_bytes` / `content_bytes` counts, by design.
- `CrdtBloatSweep` `FILTER (WHERE big)`s its percentiles and publishes
  `notes_measured` as their denominator alongside `notes`. **Byte totals stay
  over the full population** — those bytes are really on disk regardless of how
  small the note is.

## Trap 2 — staging is not a bloat oracle

Staging has 6 users, 9 vaults, average note `version` **1.9**, max 13. That is
e2e churn: notes with about two edits. Tombstone accumulation needs edit
history, so staging **structurally cannot show the bloat the epic is about**.
Its totals: 38.06 MB of state against 37.35 MB of content, ratio 1.019.

Do **not** read that as "#1707 is unnecessary". The correct conclusion is that
staging cannot answer the question and prod must.

## Trap 3 — you never need a DEK to size an encrypted column

AES-GCM ciphertext is plaintext-length plus a fixed 16-byte tag
(`Engram.Crypto.Envelope.tag_bytes/0`); the nonce lives in its own column. So
`octet_length(col) - tag_bytes()` is the **exact** plaintext size.

That is why the sweep is one aggregate query — no key material, no plaintext in
memory, no row walk, no per-tenant loop. The tag cancels out of the ratio
anyway; it is subtracted so the reported BYTE totals are true sizes rather than
sizes plus a per-row constant.

This arithmetic fails silently if broken: drop the `- 16` and every gauge is
wrong by a constant per row while still looking entirely plausible. So
`crdt_bloat_sweep_test.exs` asserts `content_bytes_total` **exactly** against
known inputs rather than merely non-zero. Verified by mutation: removing the
subtraction shifted a two-row total from 218 to 250 (16 bytes per row).

## Trap 4 — the checkpoint histogram is a biased sample

`engram_prom_ex_crdt_checkpoint_doc_*` only sees notes that were **opened**, and
re-counts a frequently synced note on **every open**. It describes "notes people
touch, weighted by how often they touch them" — not the database.

Prod, 7 days:

```promql
sum(increase(engram_prom_ex_crdt_room_start_total{job="prometheus.scrape.engram_app"}[7d])) by (source)
```

`source="handshake"` **2,726** vs `source="edit"` **17** — about 390 rooms/day.
At that rate a p99 over the live histogram needs weeks before it means anything.

That bias is the entire reason `CrdtBloatSweep` exists as the unbiased
counterpart: one pass over every stored note, `last_value` gauges (the
percentiles are already computed server-side over the true population;
re-bucketing them would only lose precision).

### Grafana datasource gotcha

The Prometheus datasource **uid** is `grafanacloud-prom`; its **name** is
`grafanacloud-calmeucalyptus520-prom`. Dashboards reference it by *name*. Query
it by uid.

## Cron placement

`10 */6 * * *` — 00:10, 06:10, 12:10, 18:10 UTC (`config/config.exs`).

**Not daily, and the cadence is not about freshness of the data.** These are
`last_value` gauges, which live only on the node that ran the job. An ECS task
replacement clears them, and on a daily cadence that is up to 24h of "No data"
on every panel after each deploy. Four cheap aggregates a day buys a 6h worst
case. The query is ~23ms on staging and extrapolates to ~4-5s at 1M notes — a
seq scan of the heap only, never the TOAST side table, because `octet_length`
reads the raw datum size off the pointer without detoasting.

:10 past the hour is deliberate: `0 * * * *` (`CleanupDeviceAuthWorker`) owns
the hour and `*/15` (`ReconcileEmbeddings`) owns the quarter-hours.

`Engram.ObanCronTest` pins two things:

1. No two **daily** workers share a minute. They share one `maintenance` queue
   (concurrency 2) and one database; a collision shows up as a slow night or a
   timeout in whichever worker lost, pointing at the worker instead of at the
   schedule.
2. `CrdtBloatSweep` collides with **nothing at all**, including sub-hourly
   entries. `slots/1` expands every expression to its full set of
   minutes-of-day — a sub-hourly entry expands across all 24 hours — so one set
   intersection covers both cases. (An earlier version claimed to compare
   sub-hourly entries on minute-of-hour; it never did, and the branch that
   supposedly did it was a verified no-op.)

Global non-overlap is deliberately **not** asserted — those two already share
the top of every hour by design, and have since long before this test.

## Gotchas

- The sweep **refuses** (`{:error, :tenancy_unsafe}`) when RLS is enforced and
  no maintenance pool is configured. `notes` carries RLS, so the query would
  return zero rows and "0 notes, ratio 0" is indistinguishable from a healthy
  empty database — a lying oracle whose gauges would be believed. Same guard and
  reasoning as `Engram.Workers.OrphanSweep`.
- The checkpoint sample is taken **pre-flatten** on purpose, so #1707 reads the
  bloat the gate is meant to catch rather than what a previous flatten already
  reclaimed. Today the gate never fires, so the two readings are equal.
- `@bloat_threshold` (5) in the sweep must match the `le` bucket on the `>5x`
  panel of the engram-crdt dashboard. Changing one without the other makes them
  disagree silently.
- No `note_id` / `vault_id` / `user_id` metadata anywhere here — unbounded
  labels, per the 2026-07-02 cardinality audit. The distribution *is* the answer.
- `measurements` is a spelled-out `@type` rather than `map()` so **dialyzer**
  catches a key renamed in one place and not the other. It does **not** catch a
  measurement added with no matching PromEx gauge — nothing does. Four lists
  must be edited together by hand: the map in `measure/0`, the `@type`, the
  `last_value` list in `Engram.PromEx.Crdt`, and the hardcoded key list in
  `Engram.PromEx.CrdtTest`.
- `CrdtBloatSweep.measure_and_emit/0` is public so the sweep can be run by hand
  without waiting for a cron slot — and it carries the tenancy guard **itself**
  for that reason. The guard used to live in `perform/1`, which left the
  advertised hand-invocation route bypassing it: one `iex` call on a misconfigured
  SaaS node writes `notes=0, ratio=0` into gauges that never expire.
- A **frozen** sweep is invisible on the value panels: `last_value` never
  expires, so a job that has been failing for a week serves its last reading and
  `absent()` cannot see it, because the series is still there.
  `measured_at_unix` exists only so `time() - it` can. Alert on the age, never
  on the values.
- `bloat_ratio_max` and `notes_over_threshold` are computed over
  `notes_measured`, so they exclude sub-floor notes. A note written then fully
  emptied scores the highest ratio in the database and is deliberately not in
  either — its ratio is Yjs framing over nothing, not tombstone accumulation.
- The dashboard's checkpoint-rate panel must read `…_state_bytes_count`, not
  `…_bloat_ratio_count`. The ratio is omitted below the floor, so its count runs
  ~37% low (staging) and is not the checkpoint count.

## References

- Issues: #1706 (this telemetry), #1707 (the flatten-gate rework it feeds),
  #609 (history + trash epic — `state_bytes_total` vs `content_bytes_total` is
  its reclaimable-storage estimate)
- `docs/context/crdt-room-lifetime-and-drain.md` — where `room_start{source}`
  comes from
