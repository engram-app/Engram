# Engram.Cache: invalidation contracts and test traps

_Last verified: 2026-10-09_

The per-module `NodeLocalEts` macro and `Engram.PgNotifications` are gone;
every node-local cache is an entry in `Engram.Cache.Registry` served by
`Engram.Cache`. Design, how to add a cache, and the pending-marker guard:
`request-query-budget.md`.

## OverrideCache invalidation contract

`lib/engram/billing/override_cache.ex` (PR #539) — 60s-TTL ETS cache of `user_limit_overrides` lookups. Caches hits AND misses. Three invalidation channels (registry entry `:billing_override`):

1. **DB trigger**, AFTER-write trigger on `user_limit_overrides` → `pg_notify('user_limit_overrides_changed', user_id)` → every node LISTENs through `Engram.Cache.Listener`. `:billing_entitlement` (resolved tier + limit matrix) is evicted by the same channel. This is what makes **raw SQL grants** (support runbook, e2e helpers) take effect immediately, no app-level call needed.
2. **Cluster.CacheSync** — `Engram.Cache.evict/2` / `evict_all/1` broadcast to peers (after the caller's transaction commits).
3. **OverrideExpirySweep** — calls `evict_all` when it deletes expired rows.

**ExUnit GOTCHA:** sandbox transactions roll back, so the trigger's NOTIFY never fires. A test that inserts an override AFTER the same user's limits were already resolved MUST call `OverrideCache.evict(user.id)` explicitly — same idiom as `PlanCache.invalidate_all/0`; documented at the factory.

## GateCache contract

`lib/engram/onboarding/gate_cache.ex` (PR #539) — caches the `RequireOnboarding` PASS verdict only (never failures), 60s TTL. Eviction write-sites:

- `Vaults.delete_vault`
- `Billing.broadcast_subscription_activated` — the chokepoint for ALL paddle event clauses
- `Onboarding.set_profile`
- `Legal.VersionCache` bump — calls `GateCache.evict_all/0` when the terms floor moves

**Rule:** anyone adding a new pass→fail transition (e.g. a new gate criterion) MUST add an eviction site, or explicitly accept up to 60s of stale PASS.

## Splinter CI gate: `SET search_path` on ALL plpgsql functions

The `function_search_path_mutable` advisory fails the unit-tests job. For trigger functions touching only pg_catalog builtins, use:

```sql
LANGUAGE plpgsql SET search_path = ''
```

## priv/repo/structure.sql is a stale point-in-time artifact

It is NOT regenerated per migration (it predates the June-6 migrations). CI lints schema from the live migrated ephemeral DB, not from this file. **Don't waste time regenerating it in migration PRs.** Its only job is the baseline replay on an empty schema — see `pg18-uuidv7-prod-crashloop-2026-06-11.md` for why that's a wreck-and-recreate mechanic.

## Engram.Cache.Listener: the one LISTEN connection

`Engram.Cache.Listener` holds the node's single LISTEN connection and routes
each NOTIFY to the registry entry whose `pg_channel` matches. For future
trigger-driven invalidation add a `pg_channel` to the registry entry; do NOT
mint new `Postgrex.Notifications` connections. On every (re)connect the
Listener clears every cache with a channel, because NOTIFYs sent while it was
down are lost.

## Test trap: pending evictions and `clear_local`

`evict/2` and `evict_all/1` run in `Repo.after_commit/1`, so inside a tenant
transaction they fire only at COMMIT. A test that evicts inside a sandbox
transaction and then reads sees the stale entry, because the sandbox never
commits. Use `Engram.Cache.evict_local/2` or `clear_local/1` in tests, and set
cache state explicitly in anything that counts queries (see "The budget test"
in `request-query-budget.md`). Cluster broadcast reaches peers only, so there
is no self-echo that wipes an entry cached right after a clear (the old
`NodeLocalEts` `evict_all` race, which needed a `:sys.get_state` drain).
