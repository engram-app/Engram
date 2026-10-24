# Context Doc: Measuring CRDT doc bloat — the traps in the numbers

_Last verified: 2026-10-24_

## Status

Working. Telemetry shipped for #1706 (`checkpoint_doc` histograms +
`state_sweep` gauges). Prod answered the question on 2026-10-03: 34.5 MB of
state against 34.2 MB of content (ratio 1.0097), p99 1.57, zero notes over 5x.
The flatten-gate rework (#1707) is closed as not worth doing; these gauges are
the tripwire.

Reopen when any of these holds on the engram-crdt dashboard:
`notes_over_threshold` non-zero and sustained, `bloat_ratio_p99` above ~3, or
`state_bytes_total` above 1.5x `content_bytes_total`.

## Trap 0 — ratio alone flags heavy editing that costs nothing (#2097)

On 2026-10-20 the over-threshold alert fired for one note: 712 checkpoints in
10 hours, 19 KB of state over 3.4 KB of content (ratio 5.7). Each checkpoint
leaves ~27 B of deletion history; that is normal heavy editing and no bytes
worth reclaiming. So `notes_over_threshold` now counts a note only when the
ratio is over 5x **and** the stored state is at least 64 KB
(`Engram.Notes.CrdtBloat.alert_min_state_bytes/0`, the one source of truth).

"Edits" in that issue means **checkpoints**, i.e. `notes.version` bumps, not
keystrokes: the debounce folds many keystrokes into one checkpoint, and REST /
MCP writes bump `version` too. The rate signal for a runaway writer is its own
pair of gauges, `notes_save_rate_over_threshold` (notes written more than
`CrdtBloat.save_rate_threshold/0` = 120 times in the hour) and
`save_rate_max_per_hour`. The sweep computes them in its one aggregate pass:
the ids and versions of notes whose `updated_at` is past the previous sweep,
diffed against that sweep's baseline (`:crdt_sweep_versions` cache,
node-local, 3h TTL). Two consequences:

- No baseline (first run on a node, a run that landed on a different ECS task,
  or a gap over 3h) leaves both keys **out** of the event, so the gauges keep
  their last value instead of reporting a fake 0. Read them with
  `measured_at_unix` like every other sweep gauge.
- A note first written in this window has no baseline version, so a loop that
  starts mid-hour shows one sweep later.

## What This Is

`crdt_state_ciphertext` is the largest column in the database and it grows with
edit count, not with note length. The bloat ratio `state_bytes / content_bytes`
is how far the encoded Yjs doc runs ahead of the text it encodes. This doc is
about the four ways that number lies to you, and the cron detail that keeps the
sweep honest.

Code:

- `lib/engram/notes/crdt_bloat.ex` — the eligibility floor
- `lib/engram/notes/crdt_checkpoint.ex` — per-checkpoint (biased) sample
- `lib/engram/workers/crdt_bloat_sweep.ex` — whole-population sweep, hourly
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

Do not read staging as an answer either way. Prod is the only oracle (see
Status).

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

A 7-day window ending in the 2026-09-14 room storm read `source="handshake"`
**2,726** vs `source="edit"` **17**. That was the storm, not steady state; the
fleet baseline is 8-142 room starts/day. Either way a p99 over the live
histogram needs weeks of samples before it means anything.

That bias is the entire reason `CrdtBloatSweep` exists as the unbiased
counterpart: one pass over every stored note, `last_value` gauges (the
percentiles are already computed server-side over the true population;
re-bucketing them would only lose precision).

### Grafana datasource gotcha

The Prometheus datasource **uid** is `grafanacloud-prom`; its **name** is
`grafanacloud-calmeucalyptus520-prom`. Both survived the 2026-09-26 move to
self-hosted Grafana. Dashboards reference it by *name*. Query it by uid.

Query the sweep gauges over a 14d window: use a step of at least 1h (the cadence)
or the panel aliases to gaps.

## Trap 5: `version` counts checkpoints, not edits

`notes.version` bumps once per **checkpoint**, and a checkpoint is debounced:
one typing burst in Obsidian folds many keystrokes into about two checkpoints.
REST and MCP writes bump it too. So "this note has N versions" means N saves,
not N edits, and a high bloat ratio on a small note is usually one person
typing, not a loop.

Real case, 2026-10-24 triage: the bloat alert fired on a 5.7x ratio for a
3.4 KB note. It was one human editing in Obsidian. A small note's ratio
swings hard on a few tombstones; the bytes involved were trivial.

What changed (Engram#2175, merged to main 2026-10-24, not yet released; alert rule engram-infra#1578,
merges only after #2175 reaches prod):

- `notes_over_threshold` counts a note only when ratio > 5 **and** stored state
  >= 64 KB (`CrdtBloat.alert_min_state_bytes/0`). Small notes can no longer
  page on ratio alone.
- New gauges `notes_save_rate_over_threshold` (notes saved > 120 times/hour,
  `CrdtBloat.save_rate_threshold/0`) and `save_rate_max_per_hour`, from
  `notes.version` deltas against the previous sweep's node-local baseline.
  With no baseline (first sweep after a deploy) the keys are omitted, not 0.
- A save loop (a client rewriting a note forever) is what actually costs
  money; alert on the save rate for that, and on the byte-floored count for
  real bloat.

## Cron placement

`10 * * * *`: hourly, at :10 (`config/config.exs`).

**The cadence is not about freshness of the data.** These are `last_value`
gauges, which live only on the node that ran the job. An ECS task replacement
clears them, so the cadence is the worst-case "No data" gap after a deploy:
1h. The query is ~23ms on staging and extrapolates to ~4-5s at 1M notes, a
seq scan of the heap only, never the TOAST side table, because `octet_length`
reads the raw datum size off the pointer without detoasting.

`Engram.ObanCronTest` asserts that no two cron entries share a minute of the
day. `slots/1` expands every expression to its full set of minutes-of-day, so
a sub-hourly entry expands across all 24 hours and one set intersection
covers every pair. All entries share the 2-slot `maintenance` queue and one
database; a collision shows up as a timeout in whichever worker lost, pointing
at the worker instead of at the schedule.

## Gotchas

- The sweep **refuses** (`{:error, :tenancy_unsafe}`) when RLS is enforced and
  no maintenance pool is configured. `notes` carries RLS, so the query would
  return zero rows and "0 notes, ratio 0" is indistinguishable from a healthy
  empty database — a lying oracle whose gauges would be believed. Same guard and
  reasoning as `Engram.Workers.OrphanSweep`.
- The checkpoint flatten is gone (#958, 0.60.1): it minted a rival lineage.
  The sample is the stored state; there is no pre/post-flatten distinction.
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
  `Engram.PromEx.CrdtTest`. The two save-rate keys are `optional` in the type
  because they are omitted without a baseline.
- `CrdtBloatSweep.measure_and_emit/0` is public so the sweep can be run by hand
  without waiting for a cron slot — and it carries the tenancy guard **itself**
  for that reason. The guard used to live in `perform/1`, which left the
  advertised hand-invocation route bypassing it: one `iex` call on a misconfigured
  SaaS node writes `notes=0, ratio=0` into gauges that never expire.
- The sweep gauges are `last_value` per ECS task, and two tasks hold readings
  from different runs. Aggregate with `max`, never `sum`.
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

- Issues: #1706 (this telemetry), #1707 (flatten-gate rework, closed),
  #609 (history + trash epic — `state_bytes_total` vs `content_bytes_total` is
  its reclaimable-storage estimate)
- `docs/context/crdt-room-lifetime-and-drain.md` — where `room_start{source}`
  comes from
