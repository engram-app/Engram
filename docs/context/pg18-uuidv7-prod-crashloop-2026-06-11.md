Title: PG18/UUIDv7 prod crash-loop (2026-06-11) — missed DB wipe during cutover

## Symptom
After Engram PR #524 (`feat(pg18,uuid): PG18 + UUIDv7 PK rework`, merge `cac5ebc`) was released to prod, the backend crash-looped on boot (ECS task-def `engram-saas-prod:54`, image `sha-cac5ebc`):

```
** (ArgumentError) cannot load `1` as type Ecto.UUID for field `id` in schema Engram.Legal.TermsVersion
Runtime terminating during boot (terminating)
```

ECS deployment circuit breaker held the prior healthy rev 53 (`sha-950e3b0`), so no outage — but all backend deploys were blocked.

## Root cause (NOT a code bug in #524)
The PG18/uuidv7 rework is a **wreck-and-recreate baseline**, not a data migration. The uuid schema only materializes by replaying `priv/repo/structure.sql` on an EMPTY schema (the 2026-06-02 baseline mechanic). There is intentionally NO `ALTER ... TYPE uuid` migration anywhere. The design spec (`engram-workspace/docs/superpowers/specs/2026-06-10-pg18-uuidv7-rework-design.md`) prescribed the prod cutover as: "TF taint + recreate the RDS instance → New cluster comes up empty → baseline replay rebuilds schema."

What actually happened: engram-infra #476 bumped prod RDS PG17→PG18 **in-place** (`apply_immediately = true`, comment "the PG17 → PG18 upgrade is safe") instead of taint+recreate. The in-place engine upgrade PRESERVED all data, so:
1. `terms_versions.id` stayed an integer column (row `id = 1`).
2. The baseline migration `20260602000000` was already recorded in `schema_migrations` → skipped on boot (logs show "Migrations already up"). The baseline can only run on an empty schema (every `CREATE TABLE` in structure.sql is unconditional).
3. The Ecto schemas now declare `binary_id`/`Ecto.UUID` PKs (via the new `use Engram.Schema` macro).
4. Boot runs `lib/engram/application.ex` → `Engram.Legal.Seeder.seed()/verify()` → `Repo.get_by/Repo.one(TermsVersion)` → Ecto tries to load integer `1` as `Ecto.UUID` → ArgumentError → `Application.start` fails → crash loop.

## Fix
Honor the specced wreck-and-recreate: empty prod's schema so the uuid baseline replays, then the held image boots clean and Seeder re-seeds `terms_versions` (2 rows: ToS + Privacy, both version 2026-05-19). Engine was already on PG18, so no RDS recreate was needed — just an empty schema.

Mechanism used (no local AWS creds; driven via GitOps deploy chain): a guarded, self-disabling `Engram.Release.reset_baseline/0` that runs only when env `ENGRAM_DB_RESET_BASELINE=true` AND it detects the legacy integer-PK state (`information_schema.columns` for `terms_versions.id` data_type != 'uuid'). It runs `DROP SCHEMA public CASCADE; CREATE SCHEMA public;` then `prepare_database` + `Ecto.Migrator.run(:up, all)`. The entrypoint (`entrypoint.sh`) calls it before the existing prepare_database/migrate evals. Self-disabling detection means it can never wipe a healthy uuid DB even if the flag is left on. The flag was set in prod `ecs.tf` for one deploy then removed.

Why this is safe: after the reset, prod's DB state equals a fresh-DB state, which is exactly what CI builds and validates green on every push. The entrypoint connects as the RDS master (`engram_admin`), which owns `public`, so DROP SCHEMA succeeds.

## Lessons
- A "baseline regen / structure.sql" schema change is ONLY applied to fresh DBs. For an existing DB, the baseline row in `schema_migrations` makes it a no-op. Any such change MUST be paired with an actual DB wipe/recreate at every env — and the infra change must be a taint+recreate, NOT an in-place engine upgrade that preserves data.
- The spec's prod cutover step ("taint + recreate the RDS instance") was the load-bearing line; the in-place `apply_immediately` engine bump silently violated it.
