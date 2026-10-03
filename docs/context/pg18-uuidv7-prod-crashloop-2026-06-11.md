Title: PG18/UUIDv7 prod crash-loop (2026-06-11): missed DB wipe during cutover

_Last verified: 2026-10-03_

## What happened

PR #524 (PG18 + UUIDv7 PK rework) crash-looped prod on boot:
`cannot load 1 as type Ecto.UUID for field id in schema Engram.Legal.TermsVersion`.
The ECS circuit breaker held the previous revision, so there was no outage,
but backend deploys were blocked.

## Root cause

The rework is a **wreck-and-recreate baseline**, not a data migration. The
uuid schema only materializes by replaying `priv/repo/structure.sql` on an
EMPTY schema; there is no `ALTER ... TYPE uuid` migration. The spec said
"taint + recreate the RDS instance". engram-infra #476 instead bumped prod RDS
PG17 to PG18 **in place** (`apply_immediately`), which preserved the
integer-PK data. The baseline migration was already in `schema_migrations`, so
it was skipped, and the boot-time `Legal.Seeder` read integer ids into
`Ecto.UUID` fields.

## Fix

`Engram.Release.reset_baseline/0` (`lib/engram/release.ex`), called from
`entrypoint.sh`. It is double-gated: it runs only with
`ENGRAM_DB_RESET_BASELINE=true` AND only if `terms_versions.id` is still a
legacy integer column. It does `DROP SCHEMA public CASCADE` and replays the
baseline. **It destroys all data.** The flag was set for one prod deploy, then
removed.

## Guards now in place

- `Engram.Release.verify_schema_baseline/0` runs from `entrypoint.sh` after
  migrate and before the server boots. It raises when `terms_versions.id` is a
  legacy integer, so the deploy fails at migrate with the remedy in the
  message instead of crash-looping.
- Prod RDS has `allow_major_version_upgrade = false` (engram-infra
  `main/envs/prod/rds.tf`). It is a one-shot switch: flip it true in the same
  PR that bumps `engine_version`, then back.

## Lessons

- A "baseline regen / structure.sql" schema change is ONLY applied to fresh
  DBs. For an existing DB the baseline row in `schema_migrations` makes it a
  no-op. Any such change MUST be paired with a real DB wipe/recreate at every
  env, never an in-place engine upgrade that preserves data.
- The spec's cutover step ("taint + recreate") was the load-bearing line; the
  in-place `apply_immediately` bump silently violated it.
