# Context Doc: Fleet-path-only DataMigration bugs (maintenance pool branch untested)

_Last verified: 2026-11-11_

## Status
Working. Guard test merged to main with engram-app/Engram#2528 and #2535 (verified on origin/main 2026-11-11).

## What This Is
DataMigrations and backfill workers branch on whether the maintenance pool (`Engram.Repo.Maintenance`, set by `MAINTENANCE_DATABASE_URL`) is configured. The unit suite does not configure it, so it runs the `:per_user` path by default and the fleet-only branch never ran in tests. Prod and staging take the fleet branch.

## Environment
- Prod: maintenance pool configured (engram-infra `envs/prod/ecs_secrets.tf:120`).
- FastRaid staging: configured (engram-infra `envs/staging-fastraid/env.tf:160`).
- Unit suite / most dev: NOT configured, so `:per_user` path only.

So a bug in the fleet branch ships green and fires first on staging or prod.

## The real bug (found 2026-11-11 by a prod-scale rehearsal)
`NameTerms.left/0` used:

```elixir
subquery(from r in ..., select: 1, limit: 1000)
```

Ecto rejects a literal select inside `subquery/1`:

> subquery/cte must select a source (t), a field (t.field) or a map, got: `1`

It raised on every backfill hop AFTER the hop's commit and BEFORE the successor job insert. Oban retried the same cursor, then the chain died. Fix: `select: r.id` (engram-app/Engram#2528, #2535).

Note: `select: 1` inside `exists()` IS valid. The restriction is only for `subquery/1` and CTEs.

## The guard
`test/engram/data_migrations/maintenance_pool_registry_test.exs` (merged in #2528 / #2535):
- Iterates the DataMigration registry and runs each migration's pass and `left/0` on a real maintenance pool, started with `Engram.Test.MaintenancePool.start!` from `test/support/maintenance_pool.ex`.
- Attaches to Ecto query telemetry with `stacktrace: true` and asserts that `ReconcileNotePayloads.queue_window/2`, `FolderTable.scope/2` and `BackfillCrdtState.enqueue_missing/0` actually issue their queries on that pool (proves the fleet branch ran, not the per-user fallback).
- Migrations whose `enabled?/0` returns false at test time are NOT exercised. Two are gated by a runtime condition, not hard-disabled: `KeyAliases` runs only when `Engram.Rebuild.mode() == :on` (ServiceConfig `index_rebuild` = `"on"` and the rebuild not halted), and `PersonOriginBackfill` runs only when `Analytics.enabled?() and Analytics.person_reads_enabled?()` (PostHog project key plus personal API key set). Neither holds in the test env. Re-check coverage if the guard test ever sets those conditions.
- Known gap (post-R3 follow-up): the guard passes silently when a migration's pass makes no maintenance-pool query (`EnvelopeFormat`, `LinkResolutionKeys`, `NoteName`, `KeyAliases`, `PersonOriginBackfill`); it only prints `NO fleet query`. The fix is an explicit expected-list assertion.

## Rule for new DataMigrations / backfill workers
- Any branch taken only when the maintenance pool is configured must be covered by the registry test. Adding to the registry gets the pass and `left/0` exercised; a fleet-only helper outside those also needs a telemetry stacktrace assertion like the three above.
- New tests start the pool via `Engram.Test.MaintenancePool.start!`. Never copy the pool setup into a test file.

## Failed Approaches / Dead Ends
- Relying on the default unit suite: it only takes `:per_user`, so it cannot catch fleet-only bugs.
- Asserting only that the migration finishes: the per-user fallback also finishes, so the test passes without touching the fleet code. Hence the telemetry stacktrace check.

## Gotchas
- Errors raised after the hop commits but before the successor insert look like "Oban retried, then the chain stopped", not like a crash in the query. Check the job's error for an Ecto query-build error first.
- Known parked gap: the maintenance pool has no `lock_timeout` (`lib/engram/runtime_config.ex:292`, `repo_parameters(:maintenance)` sets only `idle_in_transaction_session_timeout`; the app pool gets `lock_timeout: "10s"`). A fleet query can wait on a lock without bound.

## References
- `docs/context/data-migrations-ledger.md` (DataMigration contract, ledger, `:done`)
- `docs/context/maintenance-db-role.md` (maintenance credential and role)
- `docs/context/maintenance-job-db-load.md` (bounded maintenance job load)
- engram-app/Engram#2528, #2535
