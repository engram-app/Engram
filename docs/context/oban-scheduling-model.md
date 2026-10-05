# Oban scheduling model

_Last verified: 2026-10-05_

When to read this: you are adding an Oban worker, a cron entry, or a code path
that marks rows for later processing.

## The model

1. **Queue work when it becomes due.** Insert the job in the same transaction as
   the change that makes it due (an edit, a delete, a plan change). A site that
   only nulls a hash and waits for a cron is the anti-pattern: until 0.43,
   index-cap changes, orphan repair and plan upgrades waited up to 15 minutes,
   and then a capped batch.
2. **The queue is the throttle.** Queue concurrency and job priority set the
   rate (backfill runs at priority 9, behind every live edit; Voyage 429s
   snooze). A discovery job never caps how much it queues per tick.
   `ReconcileEmbeddings` capped a tick at 500 notes every 15 minutes, so the
   0.42.0 rebuild of ~4,200 notes took ~2 h while each batch drained in ~2 min.
3. **Crons are backstops.** They catch what the event path missed, and they do
   a full catch-up each run: page through everything (stamp-and-select pages,
   or a keyset cursor), never "the first N".
4. **A version bump starts with the deploy.** A queue-running node queues one
   reconcile sweep at boot (`Engram.Application.boot_sweep_child/1`).
5. **Every run says what it did.** One `:info` line with counts. Prod logs at
   `:info`, so a `:debug` "MUST log" line never reaches prod.

`ReconcileEmbeddings.kick/0` is the event hook for anything that marks notes
for re-indexing: it queues a sweep now, deduplicated while one is pending.

## Cron rules

- **No two entries share a minute of the day.** They share the 2-slot
  `maintenance` queue and one database. `ObanCronTest` enforces this globally.
- Minute map: reconcile `:x2/:x7`, device-auth `:04/:19/:34/:49`, hourly jobs
  on `:x3/:x8` or `:10`, dailies on `:00/:16/:25/:30/:40`.
- Cheap cleanup and retention run hourly or more often, so each run is small.
- A job whose output is an alert (Paddle drift, fair-use) runs at the cadence
  of the question it answers. Running it more often only repeats the alert.

## Checklist for a new worker

- `max_attempts` set on purpose (Oban's default is 20).
- `unique` for anything a cron or a burst of events can enqueue twice. Note
  that `Oban.insert_all` ignores `unique`: dedupe by hand, as
  `EmbedNote.reject_already_queued/2` does.
- An explicit `timeout/1`.
- A queue chosen on purpose: `maintenance` is cron backstops only, `events`
  is small follow-ups a user's action triggers (ObanQueueConfigTest).
- Idempotent, and stated as such in the moduledoc.
- One `:info` summary line per run.

## Still owed

- Expiries scheduled at their time (exports, overrides) instead of swept.
- Retention via time-partitioned tables instead of `DELETE` loops.
- `InactivityCleanup` as one job per user.
- Queue-lag metrics (age of the oldest pending job per queue) and alerts.
- Sizing `embed`/`indexing`/`crdt_checkpoint` against prod's single dirty CPU
  scheduler: Oban concurrency is not the throttle the NIFs see.
