# Context Doc: NodeLocalEts evict_all self-broadcast race

_Last verified: 2026-09-26_

## Status
Working (fix landed in tests; the underlying self-broadcast behavior is intentional and stays as-is).

## What This Is
Any cache built with `use Engram.Cache.NodeLocalEts` and `cache_sync: true` plus a `sync_evict_all` tag has an `evict_all/0` that clears ETS locally AND calls `Engram.Cluster.CacheSync.broadcast/1`. That broadcast is a `Phoenix.PubSub.broadcast` to every subscriber of the cache-sync topic, including the broadcasting node's own cache GenServer. The GenServer's `handle_info({:cache_sync, tag}, state)` calls `clear_local/0`, but only whenever it next drains its mailbox, not synchronously. Cache writes (`cache_fetch` -> `cache_put`) go straight to ETS from the calling process, never through the GenServer.

Consequence: a cache entry written right after `evict_all/0` on the same node can be wiped later, whenever the GenServer finally processes the queued self-broadcast. In prod this is harmless (it just looks like a cache miss). In tests it is not: a previous test's `on_exit(fn -> Cache.evict_all() end)` leaves a queued clear message; the next test caches entries, then anything that forces the GenServer to run its mailbox (for example `:sys.get_state(Cache)` used as a synchronization barrier after sending a pg notification) processes the stale clear and wipes the entries the test just cached.

Known affected caches (anything using `cache_sync: true` + `sync_evict_all`, grep `lib/` for the option pair to find new ones):
- `lib/engram/billing/entitlement_cache.ex` (`:billing_entitlement_evict_all`)
- `lib/engram/billing/override_cache.ex` (`:billing_override_evict_all`)
- `lib/engram/onboarding/gate_cache.ex` (`:version_evict_all`)

## Environment
Elixir/Phoenix backend, `lib/engram/cache/node_local_ets.ex` macro. Applies to any node (dev, CI, prod), but only surfaces as a real bug in ExUnit, where tests share the GenServer's mailbox timing across test boundaries.

## Symptom Seen
CI unit-tests red on `engram-app/Engram` PR 1789: `Engram.Billing.EntitlementCacheTest` "a Postgres notification for the user evicts their cached entry" failed with:

```
** (RuntimeError) should not run
```

at `assert :other = EntitlementCache.fetch(other_id, fn -> raise "should not run" end)`.

Root cause: a prior test's `on_exit(fn -> EntitlementCache.evict_all() end)` queued a `{:cache_sync, :billing_entitlement_evict_all}` self-broadcast. The failing test cached `other_id`, then a `:sys.get_state(EntitlementCache)` call (used elsewhere in the test as a barrier after sending a pg notification) forced the GenServer to drain its mailbox, which processed the queued clear and wiped `other_id` before the assertion ran.

Did not reproduce locally across 8 random seeds, the GenServer usually drains its mailbox before the next test starts. CI's scheduling/load is what exposes the race; do not treat a clean local run as proof the race is gone.

## Key Commands / Patterns

**Deterministic repro** (proves the mechanism, not the flake):
```elixir
:sys.suspend(pid)               # freeze the cache GenServer's mailbox processing
EntitlementCache.evict_all()    # local clear happens immediately, self-broadcast queues
EntitlementCache.fetch(id, fn -> :value end)  # writes straight to ETS, bypasses the GenServer
:sys.resume(pid)
:sys.get_state(pid)             # forces the queued clear to run
EntitlementCache.fetch(id, fn -> raise "gone" end)  # raises: entry was wiped
```

**Fix pattern**: any test that caches an entry and later forces the GenServer to run (via `:sys.get_state`, or anything that synchronously round-trips through it) needs to drain a possible queued self-broadcast from the previous test FIRST, before that test does anything else. Landed in `test/engram/billing/entitlement_cache_test.exs` (commit `a6c76f99`):

```elixir
setup do
  # evict_all/0 also CacheSync-broadcasts to this node's own GenServer, so a
  # previous test's on_exit can leave a queued "clear everything" message.
  # Unprocessed, it wipes entries this test caches the moment anything
  # (like the :sys.get_state below) makes the GenServer run. Drain it first.
  :sys.get_state(EntitlementCache)
  on_exit(fn -> EntitlementCache.evict_all() end)
  :ok
end
```

The `:sys.get_state` barrier must be the first line of `setup`, before `on_exit` is even registered for this test.

## Failed Approaches / Dead Ends
- Assuming a clean local run (any number of seeds) disproves the race. It does not; the GenServer's mailbox timing under CI load is the trigger, not test logic.
- Treating `Engram.Cluster.CacheSync`'s "own broadcast is harmless" module doc as covering this case. That claim is true for prod (eviction is idempotent, a redundant clear costs nothing), but it says nothing about WHEN the self-broadcast is processed relative to a test's subsequent writes. The two are different claims, prod correctness versus test-timing determinism.

## Gotchas
- The bug is invisible from the cache's own module code, everything in `entitlement_cache.ex` and `override_cache.ex` looks correct in isolation. The trap is entirely in `NodeLocalEts`'s shared self-subscribe behavior (`cache_sync: true` -> `Engram.Cluster.CacheSync.subscribe()` in `init/1`), so review the macro's contract, not just the cache module, when this kind of flake shows up.
- Any NEW cache adopting `cache_sync: true` with `sync_evict_all` inherits this risk automatically and needs the same `:sys.get_state(CacheModule)` drain barrier in any test that caches then forces the GenServer to run.
- `cache_fetch`/`cache_put` writing straight to ETS (bypassing the GenServer) is what makes the window exploitable: if writes went through the GenServer too, they'd naturally serialize after the queued clear.

## References
- `lib/engram/cache/node_local_ets.ex` (shared macro, `:cache_sync` / `:sync_evict_all` options)
- `lib/engram/billing/entitlement_cache.ex`, `lib/engram/billing/override_cache.ex`, `lib/engram/onboarding/gate_cache.ex` (sibling caches with the same option pair)
- `lib/engram/cluster/cache_sync.ex` (`broadcast/1`, `subscribe/0`)
- `test/engram/billing/entitlement_cache_test.exs` (fix, commit `a6c76f99`)
- `docs/context/perf-caching-invalidation.md` (OverrideCache / GateCache invalidation contracts, general CacheSync usage)
