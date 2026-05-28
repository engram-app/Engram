# Clustering-Readiness Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the 4 node-local-state gaps that misbehave under 2+ clustered backend nodes, so the backend is cluster-correct on AWS ECS while self-host stays single-node and dependency-free.

**Architecture:** (1) A runtime-pluggable rate-limiter façade delegating to a compile-time ETS limiter (default) or a compile-time Redis limiter (SaaS opt-in), with fail-open + telemetry when Redis is unreachable. (2) One shared `Engram.PubSub`-backed cluster cache-invalidation helper used by both `DekCache` and `VersionCache` so a mutation on one node evicts peers. (3) ECS DNS cluster discovery via a release `env.sh.eex` + shared cookie.

**Tech Stack:** Elixir 1.17 / Phoenix 1.8, Hammer 7.3 (`hammer_backend_redis ~> 7.0`), Phoenix.PubSub, `:persistent_term`, ETS, `:peer` (test cluster), ExUnit.

**Spec:** `engram-workspace` · `docs/superpowers/specs/2026-05-27-clustering-readiness-fixes-design.md`
**Umbrella issue:** engram-app/Engram#325 · **Infra dep:** engram-app/engram-infra#158 (ElastiCache)

---

## Resolved pre-work findings (do not re-derive)

- **Hammer v7 Redis backend EXISTS:** `hammer_backend_redis ~> 7.0` (latest 7.1.0) supports the v7 `use Hammer, backend: Hammer.Redis` API. Fix 1 is a dep-add + façade, **not** a custom backend.
- **`use Hammer, backend:` is compile-time.** Self-host and SaaS ship the *same* release artifact, so backend choice must be a **runtime** decision → façade delegating to two concrete limiter modules. Call sites (`EngramWeb.RateLimiter.hit/3`, `.reset_buckets!/0`) stay unchanged.
- **Return contract everywhere:** `{:allow, count} | {:deny, retry_after_ms}`. Fail-open returns `{:allow, 0}`.
- **No runtime legal-publish path exists today** (versions seed at boot, `application.ex:60`). Fix 3's value: make `VersionCache.invalidate_all/0` broadcast so a reseed on any node (rolling deploy, future admin publish) evicts peers, which then reload the new rows from the shared DB.
- **Caches share the DB.** Cross-node "invalidate" = "drop your stale local copy and reload shared state" — correct for both DEK (rewrapped DEK row) and version (new version rows).
- **No `:peer`/cluster test helper exists yet** — Task 5 adds a minimal, sandbox-free one.

## Test strategy (decided)

Cross-node invalidation is proven in two layers:

1. **Deterministic single-node real-PubSub round-trip (every CI run).** Start the *real* subscriber, drive the *real* broadcast, assert local eviction — exercising the actual topic string + message shape + subscription wiring end-to-end. Catches wiring mismatches that two isolated half-tests would miss. PubSub delivers to local subscribers, so no second node needed.
2. **One real `:peer` cross-node test, sandbox-free.** Seed caches via their public API on both nodes (DekCache = ETS+binary, VersionCache = `:persistent_term` — neither needs the DB for the *eviction* assertion), broadcast on node A, assert evicted on node B. Avoiding the Ecto sandbox removes the main flakiness source. Covers the BEAM-distribution delivery hop once.

Redis cross-node sharing → a `@tag :redis_integration` test against a real Redis (mirrors the existing `:qdrant_integration` exclusion pattern). Fix 4 (discovery) is validated by a deploy-time smoke check, not a unit test.

---

## File Structure

**Create:**
- `lib/engram_web/rate_limiter/ets.ex` — compile-time ETS Hammer limiter.
- `lib/engram_web/rate_limiter/redis.ex` — compile-time Redis Hammer limiter.
- `lib/engram/cluster/cache_sync.ex` — shared PubSub broadcast/subscribe helper + topic/message shape.
- `lib/engram/legal/version_cache/invalidator.ex` — GenServer that subscribes and clears `VersionCache` on a cluster evict.
- `rel/env.sh.eex` — release env: long node names + ECS task IP (gated, self-host unaffected).
- `test/support/cluster_case.ex` — minimal `:peer` two-node helper (sandbox-free).
- `test/engram/cluster/cache_sync_test.exs`
- `test/engram_web/rate_limiter_test.exs`

**Modify:**
- `mix.exs` — add `{:hammer_backend_redis, "~> 7.0"}`.
- `lib/engram_web/rate_limiter.ex` — becomes the runtime façade (delegates `hit/3`, `reset_buckets!/0`; fail-open + telemetry).
- `lib/engram/application.ex` — start configured limiter; start `VersionCache.Invalidator`.
- `lib/engram/crypto/dek_cache.ex` — subscribe in `init`; broadcast on `invalidate/1` + `invalidate_all/0`; `handle_info` evict clauses.
- `lib/engram/legal/version_cache.ex` — split local-only vs broadcasting invalidation.
- `config/config.exs` — default `backend: :ets`.
- `config/runtime.exs` — prod opts into `:redis` when `REDIS_URL` set; pass Redis conn to limiter child.
- `test/engram/crypto/dek_cache_test.exs`, `test/engram/legal/version_cache_test.exs` — add round-trip + peer tests.
- `CLAUDE.md` (project + `backend/CLAUDE.md`) and `docs/context/prod-hosting-decision.md` — "no Redis" note → "Redis = rate-limit store, SaaS only".

---

## Task 1: Rate-limiter pluggable backend (façade + ETS/Redis + fail-open)

**Files:**
- Create: `lib/engram_web/rate_limiter/ets.ex`, `lib/engram_web/rate_limiter/redis.ex`
- Modify: `lib/engram_web/rate_limiter.ex`, `lib/engram/application.ex`, `config/config.exs`, `config/runtime.exs`, `mix.exs`
- Test: `test/engram_web/rate_limiter_test.exs`

- [ ] **Step 1: Add the Redis backend dependency**

In `mix.exs` `deps/0`, directly after the `{:hammer, "~> 7.3"}` line:

```elixir
      {:hammer, "~> 7.3"},
      {:hammer_backend_redis, "~> 7.0"},
```

Run: `mix deps.get`
Expected: fetches `hammer_backend_redis` 7.x + `redix`.

- [ ] **Step 2: Write the failing façade test**

Create `test/engram_web/rate_limiter_test.exs`:

```elixir
defmodule EngramWeb.RateLimiterTest do
  use ExUnit.Case, async: false
  alias EngramWeb.RateLimiter

  setup do
    # default config path is ETS; reset between tests
    Application.put_env(:engram, RateLimiter, backend: :ets)
    RateLimiter.reset_buckets!()
    :ok
  end

  test "default backend is :ets" do
    Application.delete_env(:engram, RateLimiter)
    assert RateLimiter.backend() == :ets
  end

  test "hit delegates to the ETS limiter and enforces the limit" do
    key = "rl_test:#{System.unique_integer([:positive])}"
    assert {:allow, 1} = RateLimiter.hit(key, 60_000, 1)
    assert {:deny, _ms} = RateLimiter.hit(key, 60_000, 1)
  end

  test "fail-open: a raising backend allows the request and emits telemetry" do
    Application.put_env(:engram, RateLimiter, backend: :redis)

    ref = make_ref()
    :telemetry.attach(
      "fail-open-#{inspect(ref)}",
      [:engram, :rate_limiter, :backend_error],
      fn _event, meas, meta, pid -> send(pid, {:rl_degraded, meas, meta}) end,
      self()
    )

    # Redis limiter is not started in test → .hit/3 exits/raises → fail-open.
    assert {:allow, 0} = RateLimiter.hit("rl_fail:#{System.unique_integer()}", 60_000, 1)
    assert_receive {:rl_degraded, %{count: 1}, %{backend: :redis}}

    :telemetry.detach("fail-open-#{inspect(ref)}")
  end
end
```

Run: `mix test test/engram_web/rate_limiter_test.exs`
Expected: FAIL — `RateLimiter.backend/0` undefined; façade not yet built.

- [ ] **Step 3: Create the two concrete limiter modules**

Create `lib/engram_web/rate_limiter/ets.ex`:

```elixir
defmodule EngramWeb.RateLimiter.ETS do
  @moduledoc """
  Per-node ETS Hammer limiter. The default backend (self-host, dev, test, and
  any single-node deploy). `use Hammer` bakes the backend in at compile time;
  runtime backend selection lives in `EngramWeb.RateLimiter`.
  """
  use Hammer, backend: :ets
end
```

Create `lib/engram_web/rate_limiter/redis.ex`:

```elixir
defmodule EngramWeb.RateLimiter.Redis do
  @moduledoc """
  Cluster-shared Redis Hammer limiter. SaaS prod opts into this (ElastiCache,
  engram-infra#158) so per-plan/§G and Voyage-quota counters are exact across
  all nodes instead of N×-per-node. Started only when configured; the façade
  fails open if the store is unreachable.
  """
  use Hammer, backend: Hammer.Redis
end
```

- [ ] **Step 4: Rewrite the façade**

Replace the entire contents of `lib/engram_web/rate_limiter.ex`:

```elixir
defmodule EngramWeb.RateLimiter do
  @moduledoc """
  Runtime-pluggable rate limiter. Call sites use `hit/3` and (in tests)
  `reset_buckets!/0`; this module routes to the configured concrete backend:

    * `:ets`   — `EngramWeb.RateLimiter.ETS` (default; per-node, single-node correct)
    * `:redis` — `EngramWeb.RateLimiter.Redis` (cluster-shared; SaaS opt-in)

  Select via `config :engram, EngramWeb.RateLimiter, backend: :ets | :redis`.
  Because `use Hammer, backend:` is a compile-time choice, the two backends are
  separate modules and this façade dispatches at runtime — one release artifact
  serves both self-host (ETS) and SaaS (Redis).

  Failure policy: **fail-open + alert.** If the Redis backend is unreachable,
  `hit/3` allows the request (`{:allow, 0}`) and emits
  `[:engram, :rate_limiter, :backend_error]` telemetry so the degraded limiter
  is visible in CloudWatch. Availability beats abuse-protection during a store
  outage. ETS never fails this way, so the guard only wraps the Redis path.
  """

  @type hit_result :: {:allow, non_neg_integer()} | {:deny, non_neg_integer()}

  @spec hit(String.t(), pos_integer(), non_neg_integer()) :: hit_result()
  def hit(key, scale_ms, limit) do
    case backend() do
      :redis ->
        try do
          EngramWeb.RateLimiter.Redis.hit(key, scale_ms, limit)
        rescue
          error -> fail_open(error)
        catch
          :exit, reason -> fail_open(reason)
        end

      _ets ->
        EngramWeb.RateLimiter.ETS.hit(key, scale_ms, limit)
    end
  end

  @spec backend() :: :ets | :redis
  def backend do
    :engram
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:backend, :ets)
  end

  defp fail_open(reason) do
    :telemetry.execute(
      [:engram, :rate_limiter, :backend_error],
      %{count: 1},
      %{backend: :redis, reason: inspect(reason)}
    )

    {:allow, 0}
  end

  if Mix.env() == :test do
    @doc "Wipe every bucket (test setup only). Delegates to the ETS table."
    def reset_buckets! do
      :ets.delete_all_objects(EngramWeb.RateLimiter.ETS)
    end
  end
end
```

- [ ] **Step 5: Start the configured limiter in the supervision tree**

In `lib/engram/application.ex`, replace the child line
`{EngramWeb.RateLimiter, [clean_period: :timer.minutes(2)]},`
with `rate_limiter_child(),` and add this private function below `clerk_strategy_child/0`:

```elixir
  # Start the concrete limiter matching the configured backend. ETS (default)
  # needs only a clean_period; Redis needs connection opts (REDIS_URL, wired in
  # runtime.exs). Same release artifact, runtime-selected — see EngramWeb.RateLimiter.
  defp rate_limiter_child do
    case EngramWeb.RateLimiter.backend() do
      :redis ->
        opts = Application.get_env(:engram, EngramWeb.RateLimiter.Redis, [])
        {EngramWeb.RateLimiter.Redis, opts}

      _ets ->
        {EngramWeb.RateLimiter.ETS, [clean_period: :timer.minutes(2)]}
    end
  end
```

Note: `rate_limiter_child/0` always returns a child (never nil), so it sits fine inside the existing `|> Enum.reject(&is_nil/1)` pipeline.

- [ ] **Step 6: Default config = ETS**

In `config/config.exs`, add (near the other `config :engram, ...` lines):

```elixir
# Rate limiter backend. Default ETS (per-node, single-node correct, no deps).
# SaaS prod flips to :redis in runtime.exs when REDIS_URL is set (cluster-shared).
config :engram, EngramWeb.RateLimiter, backend: :ets
```

- [ ] **Step 7: Prod opt-in to Redis when REDIS_URL is set**

In `config/runtime.exs`, in the `if config_env() == :prod do` block (near the `:dns_cluster_query` line ~430), add:

```elixir
  # Rate-limiter: opt into the cluster-shared Redis backend only when a store
  # URL is provided (SaaS prod, ElastiCache — engram-infra#158). Self-host /
  # any deploy without REDIS_URL stays on the per-node ETS default. The Redis
  # limiter fails open + alerts if the store is unreachable (see RateLimiter).
  if redis_url = System.get_env("REDIS_URL") do
    config :engram, EngramWeb.RateLimiter, backend: :redis

    # `:url` + `:key_prefix` are the documented Hammer.Redis 7.x start options.
    # VERIFY exact option names against hammer_backend_redis 7.1 README before
    # first deploy; adjust here only (call sites + façade are option-agnostic).
    config :engram, EngramWeb.RateLimiter.Redis,
      url: redis_url,
      key_prefix: "engram_rl:"
  end
```

- [ ] **Step 8: Run the façade test**

Run: `mix test test/engram_web/rate_limiter_test.exs`
Expected: PASS (3 tests). The fail-open test proves a raising/exiting Redis path → `{:allow, 0}` + telemetry.

- [ ] **Step 9: Run the existing rate-limit call-site suites (no regression)**

Run: `mix test test/engram_web/plugs/rate_limit_test.exs test/engram_web/plugs/require_api_rps_budget_test.exs test/engram_web/controllers/oauth_register_controller_test.exs test/engram_web/controllers/oauth_revoke_controller_test.exs`
Expected: PASS — `reset_buckets!/0` and `hit/3` behave exactly as before on the default ETS path.

- [ ] **Step 10: Commit**

```bash
git add mix.exs mix.lock lib/engram_web/rate_limiter.ex lib/engram_web/rate_limiter/ lib/engram/application.ex config/config.exs config/runtime.exs test/engram_web/rate_limiter_test.exs
git commit -m "feat(rate-limit): runtime-pluggable backend (ETS default, Redis opt-in, fail-open)"
```

---

## Task 2: Shared cluster cache-invalidation helper

**Files:**
- Create: `lib/engram/cluster/cache_sync.ex`
- Test: `test/engram/cluster/cache_sync_test.exs`

- [ ] **Step 1: Write the failing helper test**

Create `test/engram/cluster/cache_sync_test.exs`:

```elixir
defmodule Engram.Cluster.CacheSyncTest do
  use ExUnit.Case, async: false
  alias Engram.Cluster.CacheSync

  test "broadcast reaches a subscriber on the documented topic with the documented shape" do
    :ok = CacheSync.subscribe()
    :ok = CacheSync.broadcast({:dek_evict, 42})
    assert_receive {:cache_sync, {:dek_evict, 42}}
  end

  test "topic/0 is stable" do
    assert is_binary(CacheSync.topic())
  end
end
```

Run: `mix test test/engram/cluster/cache_sync_test.exs`
Expected: FAIL — module does not exist.

- [ ] **Step 2: Implement the helper**

Create `lib/engram/cluster/cache_sync.ex`:

```elixir
defmodule Engram.Cluster.CacheSync do
  @moduledoc """
  Thin wrapper over `Engram.PubSub` for cross-node cache invalidation. Owns the
  single topic + message shape shared by the node-local caches that must evict
  cluster-wide when one node mutates shared state:

    * `Engram.Crypto.DekCache`     — after a DEK rotation / AAD rebind
    * `Engram.Legal.VersionCache`  — after a terms/privacy (re)seed or publish

  Pattern: the mutating node clears its OWN cache synchronously, then calls
  `broadcast/1` so peers evict. Each cache subscribes via `subscribe/0` from a
  process it owns and clears local state on its matching message. Receiving your
  own broadcast is harmless — eviction is idempotent and never re-broadcasts, so
  there is no loop.

  Message shape: `{:cache_sync, payload}` where payload is one of
  `{:dek_evict, user_id}`, `:dek_evict_all`, `:version_evict_all`. Each
  subscriber pattern-matches only its own payloads and ignores the rest.
  """

  @topic "cluster:cache_sync"

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Engram.PubSub, @topic)

  @spec broadcast(term()) :: :ok
  def broadcast(payload),
    do: Phoenix.PubSub.broadcast(Engram.PubSub, @topic, {:cache_sync, payload})

  @spec topic() :: String.t()
  def topic, do: @topic
end
```

- [ ] **Step 3: Run the helper test**

Run: `mix test test/engram/cluster/cache_sync_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 4: Commit**

```bash
git add lib/engram/cluster/cache_sync.ex test/engram/cluster/cache_sync_test.exs
git commit -m "feat(cluster): shared PubSub cache-invalidation helper"
```

---

## Task 3: DekCache cross-node invalidation

**Files:**
- Modify: `lib/engram/crypto/dek_cache.ex`
- Test: `test/engram/crypto/dek_cache_test.exs`

- [ ] **Step 1: Write the failing round-trip test (layer 1)**

Append to `test/engram/crypto/dek_cache_test.exs` (inside the module, after the existing tests):

```elixir
  describe "cross-node invalidation (PubSub round-trip)" do
    alias Engram.Cluster.CacheSync

    test "invalidate/1 broadcasts the documented evict message" do
      CacheSync.subscribe()
      DekCache.put(1, @dek)
      DekCache.invalidate(1)
      assert_receive {:cache_sync, {:dek_evict, 1}}
    end

    test "invalidate_all/0 broadcasts the documented evict-all message" do
      CacheSync.subscribe()
      DekCache.put(1, @dek)
      DekCache.invalidate_all()
      assert_receive {:cache_sync, :dek_evict_all}
    end

    test "a peer evict message clears the local entry" do
      DekCache.put(7, @dek)
      assert {:ok, @dek} = DekCache.get(7)

      # Simulate the message a peer node would deliver.
      CacheSync.broadcast({:dek_evict, 7})
      # Barrier: a sync call is processed after the already-queued handle_info,
      # so the eviction is guaranteed applied before we assert.
      _ = DekCache.sensitive_flag?()

      assert :miss = DekCache.get(7)
    end

    test "a peer evict-all message clears every local entry" do
      DekCache.put(8, @dek)
      DekCache.put(9, @dek)
      CacheSync.broadcast(:dek_evict_all)
      _ = DekCache.sensitive_flag?()
      assert :miss = DekCache.get(8)
      assert :miss = DekCache.get(9)
    end
  end
```

Run: `mix test test/engram/crypto/dek_cache_test.exs`
Expected: FAIL — `invalidate/1` does not broadcast; no `handle_info` for evict messages.

- [ ] **Step 2: Subscribe in init**

In `lib/engram/crypto/dek_cache.ex` `init/1`, add a subscribe call right before `schedule_sweep()`:

```elixir
    # Cross-node eviction: peers broadcast here after a DEK rotation / rebind so
    # this node drops its now-unwrappable cached DEK instead of serving it for
    # up to the TTL. See Engram.Cluster.CacheSync.
    _ = Engram.Cluster.CacheSync.subscribe()

    schedule_sweep()
```

- [ ] **Step 3: Broadcast on invalidate**

In the same file, change the public `invalidate/1` and `invalidate_all/0` to broadcast after the synchronous local clear:

```elixir
  @spec invalidate(user_id :: integer()) :: :ok
  def invalidate(user_id) do
    :ok = GenServer.call(__MODULE__, {:invalidate, user_id})
    Engram.Cluster.CacheSync.broadcast({:dek_evict, user_id})
  end
```

```elixir
  @spec invalidate_all() :: :ok
  def invalidate_all do
    :ok = GenServer.call(__MODULE__, :invalidate_all)
    Engram.Cluster.CacheSync.broadcast(:dek_evict_all)
  end
```

(`Phoenix.PubSub.broadcast/3` returns `:ok`, preserving the `:ok` contract.)

- [ ] **Step 4: Handle peer evict messages**

Add these `handle_info/2` clauses (next to the existing `handle_info(:sweep, ...)`):

```elixir
  @impl true
  def handle_info({:cache_sync, {:dek_evict, user_id}}, state) do
    :ets.delete(@table, user_id)
    {:noreply, state}
  end

  @impl true
  def handle_info({:cache_sync, :dek_evict_all}, state) do
    :ets.delete_all_objects(@table)
    {:noreply, state}
  end

  # Ignore cache_sync messages addressed to other caches.
  @impl true
  def handle_info({:cache_sync, _other}, state), do: {:noreply, state}
```

- [ ] **Step 5: Run the DekCache suite**

Run: `mix test test/engram/crypto/dek_cache_test.exs`
Expected: PASS — existing tests + 4 new round-trip tests. (Existing tests call `invalidate_all/0` in `setup`; the extra broadcast is received by this same process and is idempotent.)

- [ ] **Step 6: Commit**

```bash
git add lib/engram/crypto/dek_cache.ex test/engram/crypto/dek_cache_test.exs
git commit -m "feat(crypto): DekCache cross-node invalidation via PubSub"
```

---

## Task 4: VersionCache cross-node invalidation

**Files:**
- Modify: `lib/engram/legal/version_cache.ex`, `lib/engram/application.ex`
- Create: `lib/engram/legal/version_cache/invalidator.ex`
- Test: `test/engram/legal/version_cache_test.exs`

- [ ] **Step 1: Write the failing round-trip test (layer 1)**

Append to `test/engram/legal/version_cache_test.exs` (inside the module):

```elixir
  describe "cross-node invalidation (PubSub round-trip)" do
    alias Engram.Cluster.CacheSync
    alias Engram.Legal.VersionCache.Invalidator

    test "invalidate_all/0 broadcasts the documented evict-all message" do
      CacheSync.subscribe()
      VersionCache.invalidate_all()
      assert_receive {:cache_sync, :version_evict_all}
    end

    test "a peer evict message clears the local cache (next read reloads)" do
      insert_version(version: "2026-05-19", material: true, effective_date: nil)
      assert VersionCache.required_floor("terms_of_service") == "2026-05-19"

      insert_version(version: "2026-06-01", material: true, effective_date: ~D[2000-01-01])
      # Still memoized at the old floor until an eviction lands.
      assert VersionCache.required_floor("terms_of_service") == "2026-05-19"

      CacheSync.broadcast(:version_evict_all)
      # Barrier: sync the Invalidator so its handle_info has run.
      _ = :sys.get_state(Invalidator)

      assert VersionCache.required_floor("terms_of_service") == "2026-06-01"
    end
  end
```

Run: `mix test test/engram/legal/version_cache_test.exs`
Expected: FAIL — `invalidate_all/0` does not broadcast; `Invalidator` does not exist.

- [ ] **Step 2: Split local-only vs broadcasting invalidation**

In `lib/engram/legal/version_cache.ex`, replace `invalidate_all/0` with a local-only worker plus a broadcasting public function:

```elixir
  @doc """
  Drop every cached entry on THIS node only (no broadcast). Used by the
  cluster Invalidator on receipt of a peer eviction and as the building block
  for `invalidate_all/0`.
  """
  @spec invalidate_local_all() :: :ok
  def invalidate_local_all do
    for {{__MODULE__, _} = k, _v} <- :persistent_term.get() do
      :persistent_term.erase(k)
    end

    :ok
  end

  @doc """
  Drop every cached entry on this node AND tell peers to do the same. Call after
  a terms/privacy (re)seed or publish so every clustered node reloads the new
  version rows from the shared DB instead of serving a stale floor/hash.
  """
  @spec invalidate_all() :: :ok
  def invalidate_all do
    :ok = invalidate_local_all()
    Engram.Cluster.CacheSync.broadcast(:version_evict_all)
  end
```

- [ ] **Step 3: Create the subscriber GenServer**

Create `lib/engram/legal/version_cache/invalidator.ex`:

```elixir
defmodule Engram.Legal.VersionCache.Invalidator do
  @moduledoc """
  Subscribes to `Engram.Cluster.CacheSync` and clears this node's
  `Engram.Legal.VersionCache` when a peer publishes/reseeds terms. `VersionCache`
  is a pure `:persistent_term` module with no process of its own, so this thin
  GenServer owns the subscription and the local-clear callback.
  """
  use GenServer
  alias Engram.Legal.VersionCache

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    _ = Engram.Cluster.CacheSync.subscribe()
    {:ok, %{}}
  end

  @impl true
  def handle_info({:cache_sync, :version_evict_all}, state) do
    VersionCache.invalidate_local_all()
    {:noreply, state}
  end

  # Ignore cache_sync messages addressed to other caches.
  @impl true
  def handle_info({:cache_sync, _other}, state), do: {:noreply, state}
end
```

- [ ] **Step 4: Start the Invalidator in the supervision tree**

In `lib/engram/application.ex`, add to the `children` list immediately after `{Phoenix.PubSub, name: Engram.PubSub},` (PubSub must start first):

```elixir
        Engram.Legal.VersionCache.Invalidator,
```

- [ ] **Step 5: Confirm the boot reseed still works**

`application.ex:60` calls `VersionCache.invalidate_all()` in `maybe_seed_legal/0`, which runs *after* `Supervisor.start_link` — so PubSub + Invalidator are already up and the boot reseed now also broadcasts (peers reload from the shared DB). No change needed; verify by reading the call site.

- [ ] **Step 6: Run the VersionCache suite**

Run: `mix test test/engram/legal/version_cache_test.exs`
Expected: PASS — existing 2 tests + 2 new round-trip tests.

- [ ] **Step 7: Commit**

```bash
git add lib/engram/legal/version_cache.ex lib/engram/legal/version_cache/invalidator.ex lib/engram/application.ex test/engram/legal/version_cache_test.exs
git commit -m "feat(legal): VersionCache cross-node invalidation via PubSub"
```

---

## Task 5: Real two-node `:peer` cross-node test (layer 2)

**Files:**
- Create: `test/support/cluster_case.ex`
- Test: add a `@tag :cluster` test to `test/engram/crypto/dek_cache_test.exs`

This proves the BEAM-distribution delivery hop end-to-end, sandbox-free (the eviction assertion needs no DB).

- [ ] **Step 1: Confirm `test/support` is compiled in the test env**

Run: `grep -n "elixirc_paths" mix.exs`
Expected: shows `elixirc_paths(:test)` includes `"test/support"`. If it does not, add:

```elixir
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
```

and reference `elixirc_paths: elixirc_paths(Mix.env())` in `project/0` (only if missing).

- [ ] **Step 2: Create the minimal peer-node helper**

Create `test/support/cluster_case.ex`:

```elixir
defmodule Engram.ClusterCase do
  @moduledoc """
  Spins up a single extra BEAM node via `:peer` for cross-node PubSub tests.
  Deliberately minimal and DB-free: it starts only `Phoenix.PubSub` (name
  `Engram.PubSub`) and the cache GenServers under test on the peer, then
  connects the two nodes so PubSub's pg-based adapter fans out across them.
  Avoiding `Application.ensure_all_started(:engram)` (and thus the Ecto
  sandbox) is what keeps this deterministic.
  """

  @doc """
  Start a peer node, make this node distributed if needed, share the code paths,
  start PubSub + the given child modules on the peer, and connect. Returns the
  peer's node name. The peer is torn down on test exit via `on_exit`.
  """
  def start_peer!(children, on_exit_fun) do
    # Ensure THIS node is alive and distributed (long names).
    unless Node.alive?() do
      {:ok, _} = :net_kernel.start([:"primary@127.0.0.1", :longnames])
      Node.set_cookie(:engram_cluster_test)
    end

    {:ok, peer_pid, peer_node} =
      :peer.start_link(%{
        name: :"peer#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io
      })

    on_exit_fun.(fn -> :peer.stop(peer_pid) end)

    # Share cookie + code paths so the peer can load our modules.
    true = :peer.call(peer_pid, :erlang, :set_cookie, [Node.get_cookie()])
    for path <- :code.get_path() do
      :peer.call(peer_pid, :code, :add_pathz, [path])
    end

    :peer.call(peer_pid, Application, :ensure_all_started, [:phoenix_pubsub])
    {:ok, _} = :peer.call(peer_pid, Phoenix.PubSub, :start_link, [[name: Engram.PubSub]])

    for child <- children do
      {:ok, _} = :peer.call(peer_pid, child, :start_link, [[]])
    end

    # Connect so pg groups merge across nodes.
    true = :peer.call(peer_pid, Node, :connect, [Node.self()])
    {peer_pid, peer_node}
  end
end
```

Note on `connection: :standard_io`: this routes the peer's IO over a pipe so a crashed peer can't wedge the suite; adjust to `:peer`'s default only if the runner lacks a configured `epmd`.

- [ ] **Step 3: Write the failing cross-node DekCache test**

Append to `test/engram/crypto/dek_cache_test.exs`:

```elixir
  describe "real two-node eviction" do
    @tag :cluster
    test "invalidate on node A evicts the entry cached on node B" do
      {peer_pid, _peer_node} =
        Engram.ClusterCase.start_peer!([Engram.Crypto.DekCache], &on_exit/1)

      # Cache the same DEK on BOTH nodes.
      DekCache.put(123, @dek)
      :ok = :peer.call(peer_pid, Engram.Crypto.DekCache, :put, [123, @dek, nil])
      assert {:ok, @dek} = :peer.call(peer_pid, Engram.Crypto.DekCache, :get, [123])

      # Invalidate on THIS node; the broadcast must reach the peer.
      DekCache.invalidate(123)

      # Poll briefly for the cross-node delivery (distribution is async).
      assert eventually(fn ->
               :miss == :peer.call(peer_pid, Engram.Crypto.DekCache, :get, [123])
             end)
    end
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> true
      attempts <= 0 -> false
      true ->
        Process.sleep(20)
        eventually(fun, attempts - 1)
    end
  end
```

- [ ] **Step 4: Run it to verify it fails without distribution wired**

Run: `mix test test/engram/crypto/dek_cache_test.exs --only cluster`
Expected: initially may FAIL if the peer cannot form a cluster (epmd/longnames). Diagnose: ensure `epmd -daemon` is running and the host resolves `127.0.0.1`. Once the peer connects, the test should pass because Task 3 already broadcasts. (This task adds no production code — it is the end-to-end proof of Task 3 across real nodes.)

- [ ] **Step 5: Run it to verify it passes**

Run: `epmd -daemon; mix test test/engram/crypto/dek_cache_test.exs --only cluster`
Expected: PASS — node B's entry is evicted after node A's `invalidate/1`.

- [ ] **Step 6: Run the whole suite without the cluster tag (no regression / determinism)**

Run: `mix test`
Expected: PASS. `:cluster` tests run by default; if CI lacks `epmd`/longnames they can be excluded with `--exclude cluster` (document this in the PR, do not exclude unilaterally).

- [ ] **Step 7: Commit**

```bash
git add test/support/cluster_case.ex test/engram/crypto/dek_cache_test.exs mix.exs
git commit -m "test(cluster): real two-node DekCache eviction via :peer"
```

---

## Task 6: ECS cluster discovery config (Fix 4)

**Files:**
- Create: `rel/env.sh.eex`
- (Verify) `config/runtime.exs:430` `:dns_cluster_query` already reads `DNS_CLUSTER_QUERY`.

- [ ] **Step 1: Add the release env script for long node names**

Create `rel/env.sh.eex`:

```sh
#!/bin/sh
# Cluster ECS tasks with long node names bound to the task ENI IP so DNSCluster
# (DNS_CLUSTER_QUERY -> Cloud Map service DNS) can discover peers by resolving
# the service name to all task IPs and connecting to engram@<ip>. RELEASE_COOKIE
# is supplied via env (SOPS) so only trusted nodes cluster.
#
# Gated on ECS_ENABLE_CLUSTER: when unset (self-host, local, single-node), the
# default mix-release env (short names, no clustering) applies and DNS_CLUSTER_QUERY
# stays unset -> DNSCluster runs in :ignore mode. Self-host behavior is unchanged.
if [ -n "$ECS_ENABLE_CLUSTER" ]; then
  export RELEASE_DISTRIBUTION=name
  export RELEASE_NODE="engram@$(hostname -i | awk '{print $1}')"
fi
```

- [ ] **Step 2: Verify the runtime query wiring is present**

Run: `grep -n "dns_cluster_query" config/runtime.exs`
Expected: `config :engram, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")` — already present; no change. (The `DNSCluster` child in `application.ex:21` consumes it.)

- [ ] **Step 3: Verify the release still builds**

Run: `MIX_ENV=prod mix release --quiet 2>&1 | tail -5` (or confirm via a local Docker build if prod deps aren't installed locally)
Expected: release assembles; `rel/env.sh.eex` is picked up automatically by `mix release`.

- [ ] **Step 4: Document the deploy-time smoke check (no unit test)**

Fix 4 is validated at AWS bring-up, not in ExUnit. Record in the PR description / hosting runbook:

> After two ECS tasks are running with `ECS_ENABLE_CLUSTER=1`, `DNS_CLUSTER_QUERY=<cloud-map-dns>`, and a shared `RELEASE_COOKIE`: exec into one task and run `/app/bin/engram rpc 'IO.inspect(Node.list())'` — expect the other task's node in the list (non-empty).

- [ ] **Step 5: Commit**

```bash
git add rel/env.sh.eex
git commit -m "feat(cluster): ECS DNS discovery via release env (long names + cookie)"
```

The engram-infra side (Cloud Map service discovery, `REDIS_URL`/`DNS_CLUSTER_QUERY`/`RELEASE_COOKIE`/`ECS_ENABLE_CLUSTER` env + ElastiCache) is separate infra work (engram-infra#158); coordinate with the AWS hosting build.

---

## Task 7: Documentation follow-ups

**Files:**
- Modify: project `CLAUDE.md`, `backend/CLAUDE.md`, `docs/context/prod-hosting-decision.md` (the latter two — confirm exact "no Redis" wording before editing).

- [ ] **Step 1: Update the "no Redis" architecture note**

Find the "No GPU, no Redis" line(s) and qualify them, e.g.:

> No GPU, no Redis *for PubSub/caches* — Erlang clustering handles those natively. SaaS prod uses Redis (ElastiCache) **only** as the shared rate-limit store so per-plan/§G and Voyage-quota counters are exact across clustered nodes; self-host stays Redis-free (ETS default).

Apply the equivalent qualifier in `docs/context/prod-hosting-decision.md` wherever it asserts "no Redis".

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md backend/CLAUDE.md docs/context/prod-hosting-decision.md
git commit -m "docs: clarify Redis = SaaS rate-limit store (clustering readiness)"
```

(Project `CLAUDE.md` / `prod-hosting-decision.md` live in the **engram-workspace** repo, not the backend repo — make those edits on a workspace branch, not this backend worktree. The `backend/CLAUDE.md` note lives in the backend repo and rides this PR.)

---

## Final verification

- [ ] Run the full backend suite: `cd backend && mix test` → all green (including `:cluster` tests if `epmd` is available; otherwise note the `--exclude cluster` in the PR).
- [ ] Run the project lints/format gate per `backend/CLAUDE.md` (e.g. `mix format --check-formatted`, Credo) before opening the PR.
- [ ] Confirm the default path is untouched: with no `REDIS_URL`, the limiter starts `EngramWeb.RateLimiter.ETS`; with no `ECS_ENABLE_CLUSTER`, node names stay short and `DNSCluster` is `:ignore`.
- [ ] Open ONE backend PR (single-PR-per-feature). Link engram-app/Engram#325. PR body: list the 4 fixes, the Hammer-Redis option-name verify note (Task 1 Step 7), the `--exclude cluster` CI caveat, and the deploy-time smoke check (Task 6 Step 4).

## Self-review notes (coverage vs spec)

- Fix 1 → Task 1 (pluggable backend, default ETS, Redis opt-in, fail-open + telemetry; Hammer-Redis dep confirmed).
- Fix 2 → Tasks 2 + 3 (shared helper + DekCache evict).
- Fix 3 → Tasks 2 + 4 (shared helper + VersionCache evict; runtime-publish gap addressed via broadcasting `invalidate_all/0`).
- Fix 4 → Task 6 (DNS discovery config + cookie + node naming; smoke check).
- Shared helper requirement (spec "one small helper both use") → Task 2, consumed by Tasks 3 & 4.
- Test strategy → layer 1 in Tasks 3/4, layer 2 in Task 5, Redis-integration + smoke noted.
- Follow-ups (spec "no Redis" note) → Task 7.

**Open verify-at-implementation items:** exact `Hammer.Redis` 7.1 start option names (Task 1 Step 7); `epmd`/longnames availability on the CI runner for `:cluster` tests (Task 5 Step 4).
