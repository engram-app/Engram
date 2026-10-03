# Rate limiter & cap architecture — and why NOT Mnesia, why NOT Redis

_Last verified: 2026-10-03_

**TL;DR:** Engram rate limiting is **BEAM only, zero Redis, no database on the request path.** Every limiter, including the `ai_searches_per_day` budget, is a Hammer ETS counter behind `EngramWeb.RateLimiter`.

- **Short-window abuse/burst limiters** (preauth 60s, auth, `api_rps` 1s, Voyage RPM) and the **daily AI search budget** share one mechanism: per-node Hammer ETS + `Phoenix.PubSub` broadcast (`EngramWeb.RateLimiter.DistributedETS`). Eventually consistent, permissive on failure.
- **`ai_searches_per_day`** is spent at the cost site, `Engram.Search.spend_search_budget/1`: `RateLimiter.hit("ai_search:<user_id>", 86_400_000, cap, :ai_search)`. Fixed, epoch-aligned 24h window (a user can spend the budget either side of a boundary), and the count resets when a node restarts, so a rolling deploy hands everyone a fresh budget. Accepted on purpose (#1553): it replaced a Postgres token bucket (`Engram.Usage.DailyCap` + `usage_buckets`) that was exact and durable but cost a DB round trip per search.

Backend selection (`EngramWeb.RateLimiter.backend/0`): `:ets` (self-host / dev / test — per-node, no broadcast) | `:distributed_ets` (clustered SaaS prod, keyed on `DNS_CLUSTER_QUERY` in `runtime.exs`).

Redis removed in #684 (engram-infra #608 tore down ElastiCache).

---

## Why NOT Mnesia (do not re-attempt `hammer_backend_mnesia`)

Mnesia was the original plan (cluster-shared exact-ish counters to avoid per-node ETS N× slop). **It was rejected after research — validated twice on 2026-06-21.**

**`hammer_backend_mnesia` (latest 0.7.1, Jul 2025) does NOT replicate counters across nodes.** Its `lib/hammer/mnesia.ex` `handle_continue` only calls `:mnesia.create_table` (local `ram_copies` on whichever node starts it). The replication logic is two unimplemented stubs:

```elixir
# TODO listen for cluster changes
# TODO attempt unsplit
```

There is **no** `add_table_copy`, no node monitoring, no netsplit/unsplit. The CHANGELOG ("listen for cluster changes and replicate") and moduledoc ("distributed in-memory table") **overstate the shipped code** — don't trust them. The library's own README leads with: *"Consider using `Hammer.ETS` with counter increments broadcasted via Phoenix PubSub instead."*

Consequences:
- Using it as-is = per-node RAM table = **identical to the plain `:ets` backend, with extra Mnesia machinery and zero benefit.**
- Building replication ourselves (manual `add_table_copy` + netsplit handling) is **fragile on ephemeral Fargate node names** (Mnesia schema is node-name-bound; names churn every rolling deploy) — MongooseIM built CETS specifically to get *off* Mnesia for exactly this. And `dirty_update_counter` still isn't exact across a partition.

So Mnesia costs the most and delivers the least for this use case. Skip it.

**Also evaluated and rejected** (see commit history / issues): CETS (replicates records, not atomic increments → undercounts a shared counter; needs node-specific keys = wrong model), DeltaCrdt/Horde (no counter CRDT; LWW map clobbers concurrent increments → undercount under burst), `:global` single GenServer (throughput bottleneck + loses count on netsplit heal), hash-ring/`ex_hash_ring` (reshard resets per deploy, netsplit double-count).

## Why NOT Redis (removed)

Redis/Valkey (ElastiCache) was previously the SaaS-only shared store for exact cross-node counters. Removed because:
- It was a **side-store, not load-bearing** — BEAM already provides pub/sub (`:pg`/dist-Erlang), cache (ETS), and the job queue (Oban on Postgres) natively. On Node/Rails, Redis is the Channels backplane; on BEAM, distributed Erlang *is* the backplane.
- It was a managed service + SG + SOPS secret + SSM env to operate, ~$12/mo, and a **fail-open surface** (non-HA single node; a recreate once silently disabled rate limiting — see engram-infra `docs/context/tf-plan-operations.md`).
- The daily search budget does not need cross-deploy exactness; it biases permissive like every other limiter (see TL;DR).

## How DistributedETS avoids the echo loop / double-count

`hit/4` broadcasts `{:inc, key, scale, increment}` via `Phoenix.PubSub.broadcast_from(@pubsub, Listener_pid, ...)` — **excluding this node's own Listener** so the originating node doesn't double-count its own hit — then runs `Local.hit` (check + count). The `Listener` GenServer applies remote `:inc` via `Local.inc/3` (**count-only, never re-broadcasts**) → no echo loop. On a single node `broadcast_from` reaches zero subscribers (clean no-op), so self-host pays nothing. This is Hammer v7's official distributed-ETS pattern, run in production by hex.pm (`HexpmWeb.RateLimitPubSub`).

## Tradeoffs accepted

- **Eventual consistency**: overshoot ≈ rate × intra-cluster PubSub propagation (~ms); new nodes start empty; netsplits drop in-flight increments. All failure modes bias **permissive** — correct for abuse/burst limiters.
- **Voyage RPM** is a *global external-quota* throttle, not a per-user abuse cap, so eventual consistency can briefly exceed Voyage's account RPM (new-node/netsplit). **Accepted** (60s window ≫ ms propagation; Voyage 429s handled downstream; #685 closed). Tighten via per-node budget division if it bites.
- **Rate-limiter telemetry** is in-tree via `Engram.PromEx.RateLimiter` (`lib/engram/prom_ex/rate_limiter.ex`).

## Pointers

- Code: `lib/engram_web/rate_limiter.ex` (façade), `lib/engram_web/rate_limiter/distributed_ets.ex`, `lib/engram_web/rate_limiter/ets.ex`, `Engram.Search.spend_search_budget/1` (`lib/engram/search.ex`).
- Open follow-up: #686 (PubSub broadcast volume at scale).
