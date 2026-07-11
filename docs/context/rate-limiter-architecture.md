# Rate limiter & cap architecture — and why NOT Mnesia, why NOT Redis

_Last verified: 2026-07-08_

**TL;DR:** Engram rate limiting is **Postgres + BEAM only, zero Redis**. Two mechanisms, split by limiter character:

- **Short-window abuse/burst limiters** (preauth 60s, auth, `api_rps` 1s, Voyage RPM) → **`EngramWeb.RateLimiter.DistributedETS`**: per-node Hammer ETS counter + `Phoenix.PubSub` broadcast. Eventually consistent, permissive on failure.
- **Billing-exact daily cap** (`external_ai_searches_per_day` / `inapp_searches_per_day`) → **`Engram.Usage.DailyCap`**: a lazy-refill **token bucket in Postgres** (`usage_buckets`), durable across deploys, with an ETS fast-deny cache.

Backend selection (`EngramWeb.RateLimiter.backend/0`): `:ets` (self-host / dev / test — per-node, no broadcast) | `:distributed_ets` (clustered SaaS prod, keyed on `DNS_CLUSTER_QUERY` in `runtime.exs`).

Shipped: PRs #680 (PG cap), #684 (ETS+PubSub limiter + delete all Redis), engram-infra #608 (ElastiCache teardown). Live in prod since release `v0.5.495` (2026-06-21).

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
- The one counter that genuinely needed exactness (the billing daily cap) is better served by **Postgres** (durable across deploys, exact regardless of node count) — which ElastiCache never gave (it's wiped on failover too).

## How DistributedETS avoids the echo loop / double-count

`hit/4` broadcasts `{:inc, key, scale, increment}` via `Phoenix.PubSub.broadcast_from(@pubsub, Listener_pid, ...)` — **excluding this node's own Listener** so the originating node doesn't double-count its own hit — then runs `Local.hit` (check + count). The `Listener` GenServer applies remote `:inc` via `Local.inc/3` (**count-only, never re-broadcasts**) → no echo loop. On a single node `broadcast_from` reaches zero subscribers (clean no-op), so self-host pays nothing. This is Hammer v7's official distributed-ETS pattern, run in production by hex.pm (`HexpmWeb.RateLimitPubSub`).

## Tradeoffs accepted

- **Eventual consistency**: overshoot ≈ rate × intra-cluster PubSub propagation (~ms); new nodes start empty; netsplits drop in-flight increments. All failure modes bias **permissive** — correct for abuse/burst limiters.
- **Voyage RPM** is a *global external-quota* throttle, not a per-user abuse cap, so eventual consistency can briefly exceed Voyage's account RPM (new-node/netsplit). **Accepted** (60s window ≫ ms propagation; Voyage 429s handled downstream) — tracked in issue #685; tighten via per-node budget division if it bites.
- **Rate-limiter telemetry** is in-tree via `Engram.PromEx.RateLimiter` (`lib/engram/prom_ex/rate_limiter.ex`); #687 tracks any remaining completion.

## Pointers

- Code: `lib/engram_web/rate_limiter.ex` (façade), `lib/engram_web/rate_limiter/distributed_ets.ex`, `lib/engram_web/rate_limiter/ets.ex`, `lib/engram/usage/daily_cap.ex` (+ `daily_cap/cache.ex`), `lib/engram_web/plugs/enforce_search_cap.ex`.
- Follow-ups: #685 (Voyage overshoot), #686 (PubSub volume at scale), #687 (rate-limiter telemetry), #688 (`usage_buckets` lifecycle cleanup), #689 (daily-cap telemetry).
- Deferred infra: RDS Multi-AZ (separate HA/cost call), SOPS `redis_auth_token` removal (dead encrypted value).
