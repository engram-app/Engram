# `__before_compile__` defs lose to `defoverridable` defaults — silent handle_info shadowing

_Last verified: 2026-08-02_

Discovered building `Engram.Cache.NodeLocalEts` (PR #1203), the shared `use` macro for the node-local ETS caches.

## The trap (Elixir 1.19)

Defs generated in a `__before_compile__` hook do **not** take precedence over defaults installed via `defoverridable`. `use GenServer` injects a default catch-all `handle_info/2` and marks it `defoverridable`. A `handle_info/2` clause emitted from a `@before_compile` hook does not count as "overriding" it — the GenServer default wins, silently.

Symptom shape: no compile error, no warning, no runtime crash. The cache's eviction messages (`{:cache_sync, ...}`, Postgres `{:notification, ...}`) hit the GenServer default handler, which logs a debug-level "received unexpected message" and drops them. Cache evictions become no-ops; nothing is red anywhere.

## The rule

**Inject overridable-callback clauses from `__using__` (module-body position), never from `__before_compile__`.**

Module-body defs replace `defoverridable` defaults; before_compile-emitted defs do not. This is why `Engram.Cache.NodeLocalEts.__using__/1` assembles everything — including the `handle_info` clauses — into one module-body block (`lib/engram/cache/node_local_ets.ex:48-50`). Bonus: module-body injection also lets a cache override the injected `delete_local/1` the normal way (it's `defoverridable delete_local: 1`).

If you need before_compile for something else (e.g. accumulating attributes), keep the callback clauses out of it.

## Second trap in the same work: compile-time `if @attr` in a runtime body trips dialyzer

Writing `if @nle_cache_sync do ... else ... end` **inside** `init/1`'s body looks fine — but `@nle_cache_sync` is a compile-time literal, so one branch is provably dead and dialyzer flags it as `pattern_match`.

Fix: select function **variants** at module-body level instead of branching at runtime. The dead branch never gets compiled:

```elixir
# Variant selection happens at compile time (module-body `if` on the
# opts), so init/1 carries no dead runtime branches.
if @nle_cache_sync do
  defp subscribe_cache_sync, do: Engram.Cluster.CacheSync.subscribe()
else
  defp subscribe_cache_sync, do: :ok
end
```

Same pattern for `listen_pg/0` (`@nle_pg_channel` variant vs `defp listen_pg, do: :ok`). `init/1` just calls both unconditionally.

## Pointers

- `lib/engram/cache/node_local_ets.ex` — the macro; moduledoc restates both rules
- PR #1203 (`refactor/cache-macro`)
