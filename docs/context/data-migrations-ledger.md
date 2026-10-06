# Data migrations ledger

_Last verified: 2026-10-06_

## The rule

A data migration that must reach existing rows is an `Engram.DataMigration`
module registered in `Engram.Workers.DataMigrationsRunner` `@migrations`. It is
never an operator command and never a one-off rpc (see "Upgrades require zero
operator action" in `AGENTS.md`). The runner runs at boot (Oban Cron
`@reboot`) and hourly (minute 33), on the `:maintenance` queue. A boot within
the hour of a run is deduplicated by the worker's `unique` period: intended,
the two never overlap. Each pass runs one bounded slice of work for every
migration whose ledger row is not done. One migration raising does not stop the
others.

## The contract

- `name/0`, `version/0`, `run_pass/0`.
- `run_pass/0` returns `:done` only when it found no work. Errors, users
  skipped mid DEK rotation and jobs still in flight are `:more`.
- `:done` means no row the backfill would process still needs work, checked
  against exactly those rows (the same scan and predicate the worker uses).
- Two kinds of unfixed row, treated oppositely:
  - Rows the worker can never SELECT (deleted notes, soft-deleted vaults, for
    `CrdtStateSeed` notes backed by a `crdt_update_log` tail) are not its work.
    They are excluded from both the done predicate and the enqueue set, or the
    migration could never close and would enqueue no-op jobs every hour.
  - Rows the worker selects but FAILS on (content that never decrypts, a codec
    rejection) keep the migration open. That is by design: a closed ledger must
    not hide an unfixed row. The cost is one cheap pass (and one vault's job)
    per hour, and the stuck-migration alert surfaces it.
- So the done predicate and the enqueue set both use the worker's own selection
  predicate, never a looser one; a pair with no selectable row is not enqueued.
- Readers handle every older format. The ledger only saves work, it is not a
  correctness gate.

## Versioning

Bump `version/0` to reopen a migration. `DataMigrations.done?/2` treats a stored
higher version as done, so a rollback to older code does not redo work. Only
`true` is cached (in `:persistent_term`); a done migration never goes back to
not-done without a code change, and a code change restarts the node.

`IndexVersions` is the exception: its `name/0` embeds the chunker, keyword and
embed model versions, so bumping any of them is a new, not-done migration.

## Cross-tenant discovery

Use `DataMigrations.any_row?/1`. Never `skip_tenant_check: true` on the app
pool: FORCE RLS turns that into zero rows and the migration would close early
(#1349). `any_row?/1` uses the maintenance repo when enabled, else one query per
user inside that user's RLS context.

## Jobs without `unique`

If the backfill worker has no `unique` option, guard the enqueue with
`DataMigrations.jobs_in_flight?/1` so a running chain is not duplicated.

## Tests

`DataCase` resets the `done?` cache before every non-async test. A test that
touches `done?` must not be `async: true`, because the cache is node-global.

## Current migrations

| Name | Covers |
|---|---|
| `CrdtStateSeed` | Residue of the 2026-07-06 cutover that NULLed every `crdt_state`: each pass enqueues `BackfillCrdtState` for live-vault pairs holding a seedable note (kind note, not deleted, NULL state, no `crdt_update_log` rows) via `BackfillCrdtState.enqueue_missing/0`. A NULL-state note WITH a tail is excluded from both the enqueue and the done check, and the worker never seeds it: its real state is the un-checkpointed tail, and a snapshot seeded from content would be a second Yjs lineage that bind unions with it. Tail replay serves those notes. A selected note whose content never decrypts is a stuck row: it keeps the migration open until fixed. After each seed the worker evicts any resident room for the note (`CrdtRegistry.terminate_room/1`, no checkpoint), because a room bound before the seed holds an empty doc whose next edit would start a second lineage. |
| `IndexVersions` | Every content-current note stamped with the current chunker, keyword and embed model versions. `ReconcileEmbeddings` does the rebuild. Once done it drops the version term and skips the keyword scan, except on one tick a day (04:02 UTC) that re-verifies: a rollback then roll-forward or a restored soft-deleted vault puts stale notes back without reopening it. See `index-version-self-heal.md`. |

## Pruned (2026-10-06)

Prod audit (4,338 live notes): legacy MD5 hashes 0, missing `basename_hmac` 0,
plaintext vault slugs 0, version-stale 0. These finished one-time backfills were
deleted, not ported; do not re-add them: `ContentHashHmac`
(`BackfillContentHashHmac`, `ContentHash.Backfill`), `NoteLinkHmacs`
(`BackfillNoteLinks`, `Links.Backfill`), `VaultSlugHmac`
(`Vaults.backfill_slug_hmacs/1`), and the operator worker `ReindexKeyword`.
Read-side compatibility (32-char hash handling, `vaults.slug` reads) stays until
the contract release. Recover the code from git history if a restore ever needs it.

## Continuing self-heals

Work that is never "done" is a cron worker, not a data migration.

- `WarmCrdtHeads` (hourly, minute 48, `:maintenance`): calls
  `BackfillCrdtHead.enqueue_all/0` (live-vault pairs with a NULL `crdt_head`)
  unless a `BackfillCrdtHead` job is in flight. Every CRDT persist NULLs
  `crdt_head` (`CrdtPersistence.update_v1/4`, plus a trigger on `crdt_state`
  writes, so `CrdtStateSeed` seeding also NULLs it), and only
  `BackfillCrdtHead` re-warms it, so there is never a final "done".

## Next user

The envelope format backfill (#1872 PR 3).
