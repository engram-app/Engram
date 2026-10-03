# NodeLocalEts caches: invalidation contracts and test traps

_Last verified: 2026-10-03_

## OverrideCache invalidation contract

`lib/engram/billing/override_cache.ex` (PR #539) — 60s-TTL ETS cache of `user_limit_overrides` lookups. Caches hits AND misses. Three invalidation channels:

1. **DB trigger**, AFTER-write trigger on `user_limit_overrides` → `pg_notify('user_limit_overrides_changed', user_id)` → every node LISTENs via `Engram.PgNotifications`. `EntitlementCache` (resolved tier + limit matrix) LISTENs on the same channel. This is what makes **raw SQL grants** (support runbook, e2e helpers) take effect immediately, no app-level call needed.
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

## Test trap: `evict_all/0` self-broadcast

A cache built with `use Engram.Cache.NodeLocalEts` plus `cache_sync: true` and
a `sync_evict_all` tag (today: `EntitlementCache`, `OverrideCache`,
`GateCache`) clears ETS locally on `evict_all/0` AND broadcasts through
`Engram.Cluster.CacheSync`, which reaches its own GenServer too. The GenServer
runs the clear only when it next drains its mailbox, while `cache_fetch` /
`cache_put` write straight to ETS from the caller. So an entry written right
after `evict_all/0` can be wiped later. Harmless in prod (a cache miss).

In ExUnit it fails tests: a previous test's `on_exit(fn -> Cache.evict_all() end)`
leaves a queued clear, the next test caches an entry, then anything that makes
the GenServer run (`:sys.get_state(Cache)` as a barrier) wipes it. Symptom:
`** (RuntimeError) should not run` from a `fetch` fallback, in CI only. A clean
local run across any number of seeds proves nothing; CI load is the trigger.

Fix: drain first, as the first line of `setup` (see
`test/engram/billing/entitlement_cache_test.exs`):

```elixir
setup do
  :sys.get_state(EntitlementCache)
  on_exit(fn -> EntitlementCache.evict_all() end)
  :ok
end
```

Deterministic repro of the mechanism:

```elixir
:sys.suspend(pid)
EntitlementCache.evict_all()                       # local clear now, self-broadcast queued
EntitlementCache.fetch(id, fn -> :value end)       # straight to ETS
:sys.resume(pid)
:sys.get_state(pid)                                # runs the queued clear
EntitlementCache.fetch(id, fn -> raise "gone" end) # raises
```

Any new cache with `cache_sync: true` + `sync_evict_all` inherits this and
needs the same drain in tests that cache and then round-trip the GenServer.
