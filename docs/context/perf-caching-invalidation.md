# Perf caches + invalidation contracts (2026-06-12 audit wave)

_Last verified: 2026-06-12 (perf-audit session, PR #539)_

## Local test DB: PG18 on :5433, NOT :5432

`localhost:5432` is a stale PG16 container (`backend-postgres-1`); migrations use PG17+ params. Symptom: `unrecognized configuration parameter "transaction_timeout"` during migration.

```bash
DATABASE_URL="postgresql://engram:engram@localhost:5433/engram_test" mix test
# container: engram-dev-postgres, PG 18.4, creds engram/engram
```

Full detail (UUID-PK symptoms, drop/create recipe): `read-path-decrypt-perf.md`.

## OverrideCache invalidation contract

`lib/engram/billing/override_cache.ex` (PR #539) — 60s-TTL ETS cache of `user_limit_overrides` lookups. Caches hits AND misses. Three invalidation channels:

1. **DB trigger** — AFTER-write trigger on `user_limit_overrides` → `pg_notify('user_limit_overrides_changed', user_id)` → every node LISTENs via `Engram.PgNotifications`. This is what makes **raw SQL grants** (support runbook, e2e helpers) take effect immediately — no app-level call needed.
2. **Cluster.CacheSync** — broadcasts for app-level `evict/1` / `evict_all/0`.
3. **OverrideExpirySweep** — calls `evict_all` when it deletes expired rows.

**ExUnit GOTCHA:** sandbox transactions roll back, so the trigger's NOTIFY never fires. A test that inserts an override AFTER the same user's limits were already resolved MUST call `OverrideCache.evict(user.id)` explicitly — same idiom as `PlanCache.invalidate`; documented at the factory.

## GateCache contract

`lib/engram/onboarding/gate_cache.ex` (PR #539) — caches the `RequireOnboarding` PASS verdict only (never failures), 60s TTL. Eviction write-sites:

- `Vaults.delete_vault`
- `Billing.broadcast_subscription_activated` — the chokepoint for ALL paddle event clauses
- `Onboarding.set_profile`
- `:version_evict_all` — terms-floor bumps

**Rule:** anyone adding a new pass→fail transition (e.g. a new gate criterion) MUST add an eviction site, or explicitly accept up to 60s of stale PASS.

## Splinter CI gate: `SET search_path` on ALL plpgsql functions

The `function_search_path_mutable` advisory fails the unit-tests job. For trigger functions touching only pg_catalog builtins, use:

```sql
LANGUAGE plpgsql SET search_path = ''
```

## priv/repo/structure.sql is a stale point-in-time artifact

It is NOT regenerated per migration (it predates the June-6 migrations). CI lints schema from the live migrated ephemeral DB, not from this file. **Don't waste time regenerating it in migration PRs.** Its only job is the baseline replay on an empty schema — see `pg18-uuidv7-prod-crashloop-2026-06-11.md` for why that's a wreck-and-recreate mechanic.

## Engram.PgNotifications — reuse it

`Postgrex.Notifications` child in `application.ex` (started before OverrideCache): one dedicated LISTEN/NOTIFY connection per node, `auto_reconnect: true`. For future trigger-driven cache invalidation, register listeners on this process — do NOT mint new Postgrex.Notifications connections.
