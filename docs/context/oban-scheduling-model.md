# Oban scheduling model

_Last verified: 2026-10-30_

When to read this: you are adding an Oban worker, a cron entry, or a code path
that marks rows for later processing.

## The model

1. **Queue work when it becomes due.** Insert the job in the same transaction as
   the change that makes it due (an edit, a delete, a plan change): the
   `oban_jobs` row is the outbox and commits or rolls back with the write.
   Every single-note content write inserts one plain `NoteCommitted` job
   in its transaction (R6); never a unique insert there (its advisory lock
   is held to the end of the transaction), and never through
   `Notes.Enqueue` (its retry hides an aborted transaction). A site that
   only nulls a hash and waits for a cron is the anti-pattern: until 0.43,
   index-cap changes, orphan repair and plan upgrades waited up to 15 minutes,
   and then a capped batch.
2. **Work due at a known time is a job scheduled for that time**
   (`scheduled_at`), never a sweep that polls and never a snooze loop. A
   failed embed's cooldown inserts its `EmbedNote` retry for the cooldown's
   end; a Free budget park inserts a per-user `WakeBudgetParked` for when
   the refilling bucket can pay.
3. **The queue is the throttle.** Queue concurrency and job priority set the
   rate (backfill runs at priority 9, behind every live edit; Voyage 429s
   snooze). A discovery job never caps how much it queues per tick.
   `ReconcileEmbeddings` capped a tick at 500 notes every 15 minutes, so the
   0.42.0 rebuild of ~4,200 notes took ~2 h while each batch drained in ~2 min.
4. **Crons are backstops.** They catch what the event path missed, and they do
   a full catch-up each run: page through everything (stamp-and-select pages,
   or a keyset cursor), never "the first N". A backstop that would run often
   only while work remains queues its own successor (`schedule_in`) while it
   does and stops when it does not (`ReconcileEmbeddings`: every 3 h, chained
   every 5 min only during a version rollout or the daily re-verify). Count
   what a backstop finds that no event explains
   (`engram_prom_ex_indexing_reconcile_found_total{missed="true"}`): it
   should stay near zero.
5. **Never queue per-note work into a shut gate.** A job that only snoozes
   costs an UPDATE per wake (prod 2026-10-30: 1.4M snoozes a day from the
   Qdrant pace gate). A producer checks the gate once
   (`Rebuild.qdrant_open?/0`) and queues nothing while it is shut; a job
   that can still meet a shut gate snoozes on `Engram.Jobs.capped_backoff/4`
   by its `meta["snoozed"]`, never a fixed interval.
6. **A version bump starts with the deploy.** A queue-running node queues one
   reconcile sweep at boot (`Engram.Application.boot_sweep_child/1`).
7. **Every run says what it did.** One `:info` line with counts, zeros
   included: a silent run cannot be told apart from a statement RLS filtered
   to zero rows. Prod logs at `:info`, so a `:debug` "MUST log" line never
   reaches prod.

`ReconcileEmbeddings.kick/0` is the event hook for anything that marks notes
for re-indexing: it queues a sweep now, deduplicated while one is pending
(a scheduled chained run is pulled forward to now).

## Cross-tenant sweeps

A sweep over every tenant runs on `Repo.maintenance()` where one is
configured (prod): one pass, no tenant, the maintenance role's policies see
every row. Without it (self-host, tests) it falls back to
`Engram.Backfill.TenantScan`, one transaction per user. Never one
cross-tenant statement on the app pool: FORCE RLS filters it to zero rows and
it reports success. `ReconcileEmbeddings.scan/3` is the shape to copy; prove a
new one with a maintenance-pool test like
`reconcile_embeddings_maintenance_test.exs` (the app pool as `engram_app`,
assert no tenant-table query reaches it).

## Cron rules

- **No two entries share a minute of the day.** They share the 2-slot
  `maintenance` queue and one database. `ObanCronTest` enforces this globally.
- Minute map: reconcile `:02` every 3 h plus the 04:02 re-verify (`:x7`
  is free since R6), the stalled-checkout scan `:x4/:x9`, hourly jobs on
  `:x3/:x8` or `:10`, dailies on `:00/:16/:25/:30/:40`.
- Cheap cleanup and retention run hourly or more often, so each run is small.
- A job whose output is an alert (Paddle drift, fair-use) runs at the cadence
  of the question it answers. Running it more often only repeats the alert.

## Checklist for a new worker

- `max_attempts` set on purpose (Oban's default is 20).
- `unique` for anything a cron or a burst of events can enqueue twice. Note
  that `Oban.insert_all` ignores `unique`: dedupe with
  `Engram.Jobs.reject_pending/3`.
- An explicit `timeout/1`.
- A queue chosen on purpose: `maintenance` is cron backstops, `events` is
  small follow-ups a user's action triggers (ObanQueueConfigTest). Until the
  release after 0.43, three event workers still run on `maintenance`
  (`@moving_to_events`).
- A NEW queue ships empty one release before any worker moves onto it.
  Moved in the same release, a rollback to a build without the queue strands
  every job queued on it.
- Idempotent, and stated as such in the moduledoc.
- One `:info` summary line per run.

## Still owed

- Expiries scheduled at their time (exports, overrides) instead of swept.
- Retention via time-partitioned tables instead of `DELETE` loops.
- `InactivityCleanup` as one job per user.
- Queue-lag metrics (age of the oldest pending job per queue) and alerts.
- Sizing `embed`/`indexing`/`crdt_checkpoint` against prod's single dirty CPU
  scheduler: Oban concurrency is not the throttle the NIFs see.
