# Request Query Budget + Central Read-Through Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut per-request DB round trips (22-65 today) to the budgets in the spec, and replace the ad-hoc caches with one read-through cache module.

**Architecture:** A single `Engram.Cache` module (one owner process, one ETS table per declared cache, TTL + sweep, cluster eviction via `Engram.Cluster.CacheSync`, Postgres NOTIFY eviction) replaces `Engram.Cache.NodeLocalEts` and `Engram.Cache.PersistentTerm`. Per-request lookups (API key, user, subscription, vaults, key scope) go through it, evicted by AFTER-write triggers. MCP tool calls and CRDT channel handlers run in ONE tenant transaction with post-commit side effects. Writes read the note once under a row lock.

**Tech Stack:** Elixir 1.17 / OTP 27, Phoenix 1.8, Ecto + Postgrex, Oban (`testing: :manual`), Rustler NIF crate `native/engram_native` + `native/engram_core`.

**Spec:** Engram vault `50 Engineering/_Superpowers Specs/2026-10-09-request-query-budget-and-central-cache-design.md` (sections cited as "spec §N").

## Global Constraints

- Worktree: `/home/open-claw/documents/code-projects/engram/.worktrees/mcp-write-queries`, branch `perf/mcp-write-query-count`. Never touch `main`.
- Run every mix command as `mise exec -- mix ...` (PATH erl is OTP 26). Always set `MIX_TEST_PARTITION=_qaudit` for tests (the shared `engram_test` DB is polluted by other worktrees).
- Never pipe a gate command (`mix test | tail` returns tail's exit code). Redirect to a file, then read it.
- Before each commit: `mise exec -- mix format`, `mise exec -- mix compile --warnings-as-errors`, `mise exec -- mix credo --strict` on touched files. Dialyzer runs in the final task.
- Conventional commits, subject < 50 chars. Every commit message ends with:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
- TDD: failing test first, then implementation. Never loosen a test to make it pass.
- No em dashes in code comments, docs or commit messages.
- RLS: every tenant-table query runs inside `Repo.with_tenant/2` (or `Repo.cross_tenant/1` for deliberate cross-tenant reads). A cache never bypasses RLS: loaders run the same scoped query they replace.
- Migrations are expand-only (additive triggers/functions). Each trigger function pins `SET search_path = ''` (splinter rule), like `priv/repo/migrations/20260612100000_notify_on_user_limit_override_change.exs`.
- Security staleness bounds (spec §2): revoked API key and api_key_vaults scope changes evicted by trigger within ms; TTL backstop 30 s. User / subscription / vaults TTL backstop 60 s.
- `engram_app` has NO grant on `oban_jobs`: Oban inserts inside a tenant transaction must run after `tenant_exit` (role reset), never under the tenant role.
- If `.sobelow-skips` findings move lines, regenerate with `rm .sobelow-skips && mise exec -- mix sobelow --mark-skip-all` and diff the finding set (must be identical).

## Review Focus

1. A revoked API key used immediately after revoke on another node: must 401 (trigger NOTIFY -> evict on every node). Task 5 test "revoked key stops resolving after eviction".
2. A soft-deleted or suspended user with a cached `users` row: must get 410 / blocked as today, not served from cache. Task 5 test "user cache evicted on users UPDATE notification" plus existing `AccountDeleted` / `RotationLockCheck` plug tests stay green.
3. A write whose request transaction rolls back (tool error after a partial write): no broadcast, no fanout, no job. Task 6 test "after_commit callbacks dropped on rollback".
4. Two concurrent MCP appends to the same note: both appends land (row lock serializes; no lost update). Task 7 test "concurrent appends both land".
5. A deleted vault still in a node's vault-list cache: next request 404s (trigger on vaults evicts). Task 5 test "vault cache evicted on vaults UPDATE notification"; and the vaults trigger must NOT fire on `change_seq`-only updates (every note write bumps it). Task 4 test.

---

## File Structure

| File | Responsibility |
|---|---|
| `lib/engram/cache.ex` (create) | Public API: `fetch/3`, `get/2`, `put/3`, `evict/2`, `evict_all/1`, `evict_local/2`, `clear_local/1` |
| `lib/engram/cache/registry.ex` (create) | The ONE list of declared caches and their options |
| `lib/engram/cache/server.ex` (create) | Owner GenServer: creates tables, CacheSync subscribe, Postgres LISTEN, sweep |
| `lib/engram/cache/node_local_ets.ex`, `lib/engram/cache/persistent_term.ex` (delete in Task 3) | Old macros |
| Existing caches (modify in Task 3) | `billing/override_cache.ex`, `billing/entitlement_cache.ex`, `keyword_index/stats_cache.ex`, `oauth/cimd/jwks_cache.ex`, `onboarding/gate_cache.ex`, `onboarding/terms_cache.ex`, `usage_meters/activity_cache.ex`, `billing/plan_cache.ex`, `legal/version_cache.ex` become thin facades over `Engram.Cache` (or are deleted where a facade adds nothing) |
| `priv/repo/migrations/20261009120000_cache_eviction_triggers.exs` (create) | NOTIFY triggers on users, subscriptions, api_keys, api_key_vaults, vaults |
| `lib/engram/repo.ex` (modify) | `after_commit/1`, `after_tenant/1` hooks inside `run_with_tenant/2` |
| `lib/engram_web/controllers/mcp_controller.ex` (modify) | One tenant transaction around the tool handler |
| `lib/engram_web/channels/crdt_channel.ex` (modify) | One tenant transaction around DB handlers |
| `lib/engram/notes.ex`, `lib/engram/mcp/handlers.ex`, `lib/engram/notes/content_commit.ex`, `lib/engram/notes/crdt_persistence.ex`, `lib/engram/notes/crdt_deliver.ex` (modify) | Single locked read, no diagnostic count, fanout from committed state |
| `lib/engram/abuse/origin_stats.ex` (modify) | ETS counters + periodic flush |
| `native/engram_native/src/...`, `lib/engram/native.ex`, `lib/engram/crypto/envelope.ex` (modify, Task 9) | `envelope_open_many` |
| `test/engram/query_budget_test.exs` (create) | Budget per path; replaces the two scratch audit tests |
| `docs/context/request-query-budget.md` (create, Task 10) | How the budget, cache and request transaction work |

---

### Task 1: Query budget harness

**Files:**
- Create: `test/engram/query_budget_test.exs`, `test/support/query_recorder.ex`
- Delete: `test/engram_web/controllers/mcp_query_audit_test.exs`, `test/engram_web/controllers/rest_query_audit_test.exs` (scratch audits; their setup and path calls move into the new file)

**Interfaces:**
- Produces: `Engram.QueryRecorder.record((-> any())) :: {any(), [%{source: String.t() | nil, sql: String.t(), caller: String.t()}]}`; `Engram.QueryRecorder.format([map()]) :: String.t()`. Later tasks lower numbers in the `@budgets` map in `query_budget_test.exs`.

- [ ] **Step 1: Write the recorder** (`test/support/query_recorder.ex`, compiled in test via `elixirc_paths(:test)`):

```elixir
defmodule Engram.QueryRecorder do
  @moduledoc "Test helper: records every Repo query a function issues, with its Engram caller."

  def record(fun) do
    me = self()
    id = "query-recorder-#{System.unique_integer([:positive])}"

    :telemetry.attach(id, [:engram, :repo, :query], &__MODULE__.handle/4, me)

    try do
      result = fun.()
      {result, drain([])}
    after
      :telemetry.detach(id)
    end
  end

  @doc false
  def handle(_event, _measurements, meta, pid) do
    {:current_stacktrace, st} = Process.info(self(), :current_stacktrace)
    send(pid, {:recorded_query, %{source: meta[:source], sql: meta.query, caller: caller(st)}})
  end

  defp caller(st) do
    st
    |> Enum.filter(fn {mod, _, _, _} ->
      name = inspect(mod)
      String.starts_with?(name, "Engram") and name not in ["Engram.Repo", "Engram.QueryRecorder"]
    end)
    |> Enum.take(3)
    |> Enum.map_join(" < ", fn {mod, f, a, loc} ->
      "#{inspect(mod)}.#{f}/#{if is_list(a), do: length(a), else: a}:#{loc[:line]}"
    end)
  end

  defp drain(acc) do
    receive do
      {:recorded_query, q} -> drain([q | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  def format(queries) do
    queries
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {q, i} ->
      "#{i}. [#{q.source || "-"}] #{q.sql |> String.replace(~r/\s+/, " ") |> String.slice(0, 100)}\n     <- #{q.caller}"
    end)
  end
end
```

- [ ] **Step 2: Write `test/engram/query_budget_test.exs`.** Merge the setup and every path from both scratch audit files (read them first: they hold working calls for MCP tools, REST sync/notes/folders/tags/bootstrap/search and the CRDT channel join/handshake/update/doc_update/catchup). Structure:

```elixir
defmodule Engram.QueryBudgetTest do
  # Not async: telemetry handler is global and counts every process's queries.
  use EngramWeb.ConnCase, async: false

  alias Engram.QueryRecorder

  # Path => max queries with a warm cache. Lowered by Tasks 5-8 toward the
  # spec §7 targets; Task 10 asserts the final numbers.
  @budgets %{
    "mcp get_notes" => 23,
    "mcp write_note update" => 48,
    "mcp append_to_note" => 65,
    "mcp edit_note" => 57,
    "mcp delete_note" => 39,
    "GET sync/manifest" => 28,
    "GET notes/*path" => 28,
    "POST notes update" => 51,
    "POST notes create" => 56,
    "POST notes/append" => 62,
    "POST notes/rename" => 61,
    "DELETE notes/*path" => 33,
    "GET /api/bootstrap" => 44,
    "GET folders" => 27,
    "GET tags" => 22,
    "CRDT crdt_msg update" => 47,
    "CRDT crdt_doc_update idle" => 56
  }

  # setup: copied from the audits (user + DEK + vault + api key + grant_api_write!
  # + seeded notes + a joined CRDT socket for the channel paths).

  # One test per path. Each test: perform ONE warm-up call of the same path
  # (fills caches, as on a long-lived prod node), then
  #   {_, qs} = QueryRecorder.record(fn -> <the call> end)
  #   assert length(qs) <= @budgets[name], "#{name}: #{length(qs)} queries\n" <> QueryRecorder.format(qs)
  # and assert the call succeeded (status / tool result not isError).
end
```

Write one `test "<path name>"` per `@budgets` key with the real call copied from the audits. Set each budget to the CURRENT measured count printed by the audits (pinning; later tasks lower them).

- [ ] **Step 3: Run it.** `MIX_TEST_PARTITION=_qaudit mise exec -- mix test test/engram/query_budget_test.exs > /tmp/qb.txt 2>&1; echo $?` then read `/tmp/qb.txt`. Expected: all pass (budgets pin current counts). If a count differs from the audit by a few queries, pin the measured number.
- [ ] **Step 4: Delete the two scratch audit files.**
- [ ] **Step 5: Commit** `test: pin per-path query budgets`.

---

### Task 2: `Engram.Cache` core

**Files:**
- Create: `lib/engram/cache.ex`, `lib/engram/cache/registry.ex`, `lib/engram/cache/server.ex`
- Modify: `lib/engram/application.ex` (start `Engram.Cache.Server` after `pg_notifications_child`, before any cache user)
- Test: `test/engram/cache_test.exs`

**Interfaces:**
- Produces:
  - `Engram.Cache.fetch(atom(), term(), (-> term())) :: term()` : hit returns the value; miss runs loader, stores it (unless the value is `nil` and the cache has `cache_nil: false`), returns it.
  - `Engram.Cache.get(atom(), term()) :: {:ok, term()} | :miss`
  - `Engram.Cache.put(atom(), term(), term()) :: :ok`
  - `Engram.Cache.evict(atom(), term()) :: :ok` (local delete + `CacheSync.broadcast({:engram_cache_evict, cache, key})`)
  - `Engram.Cache.evict_all(atom()) :: :ok` (local clear + `CacheSync.broadcast({:engram_cache_evict_all, cache})`)
  - `Engram.Cache.evict_local(atom(), term()) :: :ok`, `Engram.Cache.clear_local(atom()) :: :ok`
  - `Engram.Cache.Registry.caches() :: [%{name: atom(), ttl: pos_integer() | :infinity, cache_nil: boolean(), evict_match: :key | :first_elem, pg_channel: String.t() | nil}]`
- Rows are `{key, value, expires_at_ms | :infinity}` in table `:"engram_cache_#{name}"`. All tables `:public, :set, read_concurrency, write_concurrency`, owned by `Engram.Cache.Server`. The server process is flagged `:sensitive` (some caches hold user data).

- [ ] **Step 1: Write the failing tests** (`test/engram/cache_test.exs`, `async: false`). Register a test cache by putting it in the registry under `Mix.env() == :test` (a `:test_cache` entry with ttl 50 ms, cache_nil false, and `:test_cache_nil` with cache_nil true):

```elixir
defmodule Engram.CacheTest do
  use ExUnit.Case, async: false

  alias Engram.Cache

  setup do
    Cache.clear_local(:test_cache)
    Cache.clear_local(:test_cache_nil)
    :ok
  end

  test "fetch runs the loader once and serves the cached value" do
    counter = :counters.new(1, [])
    load = fn -> :counters.add(counter, 1, 1); :value end
    assert Cache.fetch(:test_cache, :k, load) == :value
    assert Cache.fetch(:test_cache, :k, load) == :value
    assert :counters.get(counter, 1) == 1
  end

  test "an expired row reloads" do
    assert Cache.fetch(:test_cache, :k, fn -> 1 end) == 1
    Process.sleep(60)
    assert Cache.fetch(:test_cache, :k, fn -> 2 end) == 2
  end

  test "nil is not cached unless the cache opts in" do
    assert Cache.fetch(:test_cache, :k, fn -> nil end) == nil
    assert Cache.get(:test_cache, :k) == :miss
    assert Cache.fetch(:test_cache_nil, :k, fn -> nil end) == nil
    assert Cache.get(:test_cache_nil, :k) == {:ok, nil}
  end

  test "evict removes the key locally and broadcasts it" do
    :ok = Engram.Cluster.CacheSync.subscribe()
    Cache.put(:test_cache, :k, 1)
    :ok = Cache.evict(:test_cache, :k)
    assert Cache.get(:test_cache, :k) == :miss
    assert_receive {:cache_sync, {:engram_cache_evict, :test_cache, :k}}
  end

  test "a cache_sync eviction from a peer clears the local row" do
    Cache.put(:test_cache, :k, 1)
    send(Engram.Cache.Server, {:cache_sync, {:engram_cache_evict, :test_cache, :k}})
    _ = :sys.get_state(Engram.Cache.Server)
    assert Cache.get(:test_cache, :k) == :miss
  end

  test "a Postgres notification on a cache's channel evicts the payload key" do
    Cache.put(:test_cache, "abc", 1)
    send(Engram.Cache.Server, {:notification, self(), make_ref(), "test_cache_changed", "abc"})
    _ = :sys.get_state(Engram.Cache.Server)
    assert Cache.get(:test_cache, "abc") == :miss
  end

  test "first_elem caches evict every {id, _} key for a notification of id" do
    Cache.put(:test_cache_pairs, {"u1", :a}, 1)
    Cache.put(:test_cache_pairs, {"u1", :b}, 2)
    Cache.put(:test_cache_pairs, {"u2", :a}, 3)
    :ok = Cache.evict_local(:test_cache_pairs, "u1")
    assert Cache.get(:test_cache_pairs, {"u1", :a}) == :miss
    assert Cache.get(:test_cache_pairs, {"u2", :a}) == {:ok, 3}
  end

  test "sweep drops expired rows" do
    Cache.put(:test_cache, :k, 1)
    Process.sleep(60)
    send(Engram.Cache.Server, :sweep)
    _ = :sys.get_state(Engram.Cache.Server)
    assert :ets.info(:engram_cache_test_cache, :size) == 0
  end

  test "a missing table degrades to a miss and a no-op put" do
    assert Cache.get(:no_such_cache, :k) == :miss
    assert Cache.fetch(:no_such_cache, :k, fn -> :v end) == :v
  end
end
```

- [ ] **Step 2: Run, verify failure** (`Engram.Cache` undefined).
- [ ] **Step 3: Implement.**

`lib/engram/cache/registry.ex`:

```elixir
defmodule Engram.Cache.Registry do
  @moduledoc """
  Every node-local cache in the app, declared once. `Engram.Cache.Server`
  creates one ETS table per entry. Options:

    * `ttl` - ms, or `:infinity`. A backstop: freshness comes from eviction.
    * `cache_nil` - store a `nil` loader result (negative caching).
    * `evict_match` - `:key` evicts the exact key; `:first_elem` evicts every
      `{id, _}` key for `id` (a per-user cache keyed by `{user_id, x}`).
    * `pg_channel` - Postgres NOTIFY channel whose payload (a string) is the
      key to evict. Fired by AFTER-write triggers, so raw SQL is covered too.
  """

  @base [
    # entries are added by Tasks 3 and 5
  ]

  if Mix.env() == :test do
    @test_caches [
      %{name: :test_cache, ttl: 50, cache_nil: false, evict_match: :key, pg_channel: "test_cache_changed"},
      %{name: :test_cache_nil, ttl: 50, cache_nil: true, evict_match: :key, pg_channel: nil},
      %{name: :test_cache_pairs, ttl: 60_000, cache_nil: false, evict_match: :first_elem, pg_channel: nil}
    ]
  else
    @test_caches []
  end

  @spec caches() :: [map()]
  def caches, do: @base ++ @test_caches

  @spec fetch!(atom()) :: map()
  def fetch!(name), do: Enum.find(caches(), &(&1.name == name)) || raise(ArgumentError, "unknown cache #{inspect(name)}")

  @spec table(atom()) :: atom()
  def table(name), do: :"engram_cache_#{name}"
end
```

`lib/engram/cache.ex` (hot path: no GenServer calls, direct ETS; table absent -> miss):

```elixir
defmodule Engram.Cache do
  @moduledoc """
  The node-local read-through cache. `fetch/3` answers from ETS or runs the
  loader and stores its result. Caches are declared in
  `Engram.Cache.Registry`; `Engram.Cache.Server` owns the tables and applies
  cluster (`Engram.Cluster.CacheSync`) and Postgres NOTIFY evictions.

  A loader runs in the caller's process, so it keeps the caller's tenant
  context (`Repo.with_tenant/2`); the cache never widens what a query sees.
  """

  alias Engram.Cache.Registry
  alias Engram.Cluster.CacheSync

  # ponytail: no single-flight on miss; concurrent misses each run the loader.
  # Misses are rare (warm node, per-user keys). Add a per-key lock if a cold
  # key under load shows up in traces.
  @spec fetch(atom(), term(), (-> term())) :: term()
  def fetch(cache, key, loader) when is_function(loader, 0) do
    case get(cache, key) do
      {:ok, value} ->
        value

      :miss ->
        value = loader.()
        if value != nil or cache_nil?(cache), do: put(cache, key, value)
        value
    end
  end

  @spec get(atom(), term()) :: {:ok, term()} | :miss
  def get(cache, key) do
    case :ets.lookup(Registry.table(cache), key) do
      [{^key, value, :infinity}] -> {:ok, value}
      [{^key, value, exp}] -> if now() < exp, do: {:ok, value}, else: :miss
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @spec put(atom(), term(), term()) :: :ok
  def put(cache, key, value) do
    exp =
      case ttl(cache) do
        :infinity -> :infinity
        ms -> now() + ms
      end

    true = :ets.insert(Registry.table(cache), {key, value, exp})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec evict(atom(), term()) :: :ok
  def evict(cache, key) do
    :ok = evict_local(cache, key)
    CacheSync.broadcast({:engram_cache_evict, cache, key})
  end

  @spec evict_all(atom()) :: :ok
  def evict_all(cache) do
    :ok = clear_local(cache)
    CacheSync.broadcast({:engram_cache_evict_all, cache})
  end

  @spec evict_local(atom(), term()) :: :ok
  def evict_local(cache, key) do
    table = Registry.table(cache)

    _ =
      case evict_match(cache) do
        :first_elem -> :ets.match_delete(table, {{key, :_}, :_, :_})
        :key -> :ets.delete(table, key)
      end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec clear_local(atom()) :: :ok
  def clear_local(cache) do
    _ = :ets.delete_all_objects(Registry.table(cache))
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp ttl(cache), do: spec(cache, :ttl, :infinity)
  defp cache_nil?(cache), do: spec(cache, :cache_nil, false)
  defp evict_match(cache), do: spec(cache, :evict_match, :key)

  # Registry lookups are a compile-time list; persistent_term would be faster
  # but the list is a handful of maps, so Enum.find is fine.
  defp spec(cache, field, default) do
    case Enum.find(Registry.caches(), &(&1.name == cache)) do
      nil -> default
      spec -> Map.get(spec, field, default)
    end
  end
end
```

`lib/engram/cache/server.ex`:

```elixir
defmodule Engram.Cache.Server do
  @moduledoc "Owns every `Engram.Cache` table; applies cluster and Postgres evictions; sweeps expired rows."
  use GenServer

  require Logger

  alias Engram.Cache
  alias Engram.Cache.Registry

  @sweep_ms 60_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    # Tables back user data (vault names, users rows): keep them out of crash dumps.
    _ = Process.flag(:sensitive, true)

    for %{name: name} <- Registry.caches() do
      :ets.new(Registry.table(name), [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    end

    :ok = Engram.Cluster.CacheSync.subscribe()
    channels = listen_all()
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, %{channels: channels}}
  end

  # channel => [cache names]
  defp listen_all do
    by_channel =
      Registry.caches()
      |> Enum.filter(& &1.pg_channel)
      |> Enum.group_by(& &1.pg_channel, & &1.name)

    for channel <- Map.keys(by_channel), do: listen(channel)
    by_channel
  end

  defp listen(channel) do
    case Process.whereis(Engram.PgNotifications) do
      nil ->
        Logger.warning("cache: PG notifications not running; TTL-only eviction for #{channel}",
          Engram.Logger.Metadata.with_category(:warning, :cache, []))

      _pid ->
        {:ok, _ref} = Postgrex.Notifications.listen(Engram.PgNotifications, channel)
    end
  catch
    kind, reason ->
      Logger.warning("cache: failed to LISTEN #{channel} (#{kind}: #{inspect(reason)}); TTL-only eviction",
        Engram.Logger.Metadata.with_category(:warning, :cache, []))
  end

  @impl true
  def handle_info({:notification, _pid, _ref, channel, payload}, state) do
    for cache <- Map.get(state.channels, channel, []), do: Cache.evict_local(cache, payload)
    {:noreply, state}
  end

  def handle_info({:cache_sync, {:engram_cache_evict, cache, key}}, state) do
    :ok = Cache.evict_local(cache, key)
    {:noreply, state}
  end

  def handle_info({:cache_sync, {:engram_cache_evict_all, cache}}, state) do
    :ok = Cache.clear_local(cache)
    {:noreply, state}
  end

  def handle_info({:cache_sync, _other}, state), do: {:noreply, state}

  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    for %{name: name} <- Registry.caches() do
      # Delete rows whose expiry is an integer below now (:infinity rows are atoms and never match).
      :ets.select_delete(Registry.table(name), [{{:_, :_, :"$1"}, [{:is_integer, :"$1"}, {:<, :"$1", now}], [true]}])
    end

    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end
end
```

If `Engram.Logger.Metadata.with_category/3` rejects `:cache` as an unknown category, add `:cache` to its category list (check `lib/engram/logger/metadata.ex`; there is a compliance test in `test/engram/logger/log_call_compliance_test.exs`).

`lib/engram/application.ex`: add `Engram.Cache.Server` to the children right after the `pg_notifications_child` entry (around line 350), before `Engram.Billing.OverrideCache`.

- [ ] **Step 4: Run** `MIX_TEST_PARTITION=_qaudit mise exec -- mix test test/engram/cache_test.exs > /tmp/t2.txt 2>&1; echo $?`. Expected: all pass.
- [ ] **Step 5: Commit** `feat(cache): central read-through cache module`.

---

### Task 3: Port the existing caches; delete the macros

**Files:**
- Modify: `lib/engram/billing/override_cache.ex`, `lib/engram/billing/entitlement_cache.ex`, `lib/engram/keyword_index/stats_cache.ex`, `lib/engram/oauth/cimd/jwks_cache.ex`, `lib/engram/onboarding/gate_cache.ex`, `lib/engram/onboarding/terms_cache.ex`, `lib/engram/usage_meters/activity_cache.ex`, `lib/engram/billing/plan_cache.ex`, `lib/engram/legal/version_cache.ex` (+ its `Invalidator`), `lib/engram/application.ex`, `lib/engram/cache/registry.ex`
- Delete: `lib/engram/cache/node_local_ets.ex`, `lib/engram/cache/persistent_term.ex`
- Test: existing tests for each cache (`test/engram/billing/override_cache_test.exs`, `entitlement_cache_test.exs`, onboarding gate/terms tests, legal version cache tests, jwks tests, activity cache tests) must pass unchanged in behavior; update only how they reach internals (e.g. a test that sends `{:notification, ...}` to `Engram.Billing.OverrideCache` now sends it to `Engram.Cache.Server`).

**Interfaces:**
- Consumes: `Engram.Cache.*` from Task 2.
- Produces: unchanged public functions of every cache module (callers in lib do not change), except where a module is deleted and its call sites switch to `Engram.Cache` directly.
- Registry entries to add (`@base`), matching today's semantics exactly:

| name | ttl | cache_nil | evict_match | pg_channel | replaces |
|---|---|---|---|---|---|
| `:billing_override` | 60_000 | true (value is `{:hit, v}` or `:miss`, never nil; flag irrelevant) | `:first_elem` | `"user_limit_overrides_changed"` | OverrideCache |
| `:billing_entitlement` | 86_400_000 | false | `:key` | `"user_limit_overrides_changed"` | EntitlementCache |
| `:avgdl` | 600_000 | false | `:key` | nil | KeywordIndex.Stats.Cache |
| `:jwks` | 3_600_000 | false | `:key` | nil | JwksCache table only (its fetch+rate-limit logic stays in jwks_cache.ex) |
| `:onboarding_gate` | 60_000 | false | `:key` | nil | GateCache |
| `:terms` | `:infinity` | false | `:key` | nil | TermsCache |
| `:activity` | `:infinity` | false | `:key` | nil | ActivityCache |
| `:plan` | `:infinity` | true | `:key` | nil | PlanCache (persistent_term) |
| `:legal_version` | `:infinity` | true | `:key` | nil | Legal.VersionCache (persistent_term) |

- [ ] **Step 1:** For each module, read it and its tests. Rewrite the module as a facade: keep the public function names and specs, replace `cache_fetch/ets_lookup/ets_insert/delete_local/clear_local/pt_fetch` with `Engram.Cache.fetch/get/put/evict_local/clear_local`, replace the `evict/1` + `CacheSync.broadcast(tag)` wrappers with `Engram.Cache.evict/2` and `evict_all/1`. Remove `use Engram.Cache.NodeLocalEts` / `use Engram.Cache.PersistentTerm`, `start_link`, `init`, `handle_info`. Where a facade would only forward one call (TermsCache, ActivityCache, Stats.Cache), delete the module and call `Engram.Cache` at its 2-4 call sites (listed in its moduledoc / grep the module name). Keep moduledoc invariants (what is cached, why, how it is evicted) on the facade or move them into the registry entry comment.
- [ ] **Step 2:** Tag translation. Old cluster tags (`:billing_override_evict`, `:billing_entitlement_evict(_all)`, `:onboarding_gate_evict`, `:version_evict_all`, `:billing_override_evict_all`) disappear: every evict goes through `Engram.Cache.evict/2` / `evict_all/1`. `Legal.VersionCache.invalidate_all/0` must call `Engram.Cache.evict_all(:legal_version)` AND `Engram.Cache.evict_all(:onboarding_gate)` (GateCache consumed `:version_evict_all` today). Delete `Legal.VersionCache.Invalidator` if it only consumed that tag. Mixed-version cluster during rollout: old nodes broadcast old tags that new nodes ignore and vice versa; the TTLs (60 s) bound that window. Note it in the commit body.
- [ ] **Step 3:** Remove the 9 cache children from `application.ex` (the server owns the tables now). Keep `Engram.Crypto.DekCache` as is (owner-routed writes; out of scope, ledger ruling). Delete `node_local_ets.ex` and `persistent_term.ex`; `grep -rn "NodeLocalEts\|Cache.PersistentTerm" lib test` must return nothing.
- [ ] **Step 4:** Run the cache tests and everything that touches them: `MIX_TEST_PARTITION=_qaudit mise exec -- mix test test/engram/billing test/engram/onboarding test/engram/legal test/engram/oauth test/engram/usage_meters test/engram/keyword_index test/engram/cache_test.exs test/engram/query_budget_test.exs > /tmp/t3.txt 2>&1; echo $?`. Expected: pass. Then `mise exec -- mix compile --warnings-as-errors`.
- [ ] **Step 5:** `wc -l` the removed vs added lines (`git diff --stat`); record in the commit body. Commit `refactor(cache): port caches onto Engram.Cache`.

---

### Task 4: Eviction triggers

**Files:**
- Create: `priv/repo/migrations/20261009120000_cache_eviction_triggers.exs`
- Test: `test/engram/cache_eviction_triggers_test.exs`

**Interfaces:**
- Produces NOTIFY channels (payload = text key):
  - `users_changed` : `OLD.id` on UPDATE or DELETE of `users`
  - `subscriptions_changed` : `COALESCE(NEW.user_id, OLD.user_id)` on INSERT/UPDATE/DELETE of `subscriptions`
  - `api_keys_changed` : `OLD.key_hash` on UPDATE or DELETE of `api_keys` (check the column type with `\d api_keys`; if bytea, notify `encode(OLD.key_hash, 'hex')` and have Task 5 key the cache by the same hex string)
  - `api_key_vaults_changed` : `COALESCE(NEW.api_key_id, OLD.api_key_id)` on INSERT/DELETE/UPDATE of `api_key_vaults`
  - `vaults_changed` : `COALESCE(NEW.user_id, OLD.user_id)` on INSERT, DELETE, and UPDATE **only when a column other than `change_seq` / `updated_at` changed** (every note write bumps `change_seq`; a NOTIFY per write would empty the cache constantly)

- [ ] **Step 1: Write the failing test.** NOTIFY is delivered only on COMMIT, and the SQL sandbox never commits, so this test uses `Ecto.Adapters.SQL.Sandbox.unboxed_run/2` and a private `Postgrex.Notifications` connection, and deletes what it created:

```elixir
defmodule Engram.CacheEvictionTriggersTest do
  use ExUnit.Case, async: false

  alias Engram.Repo

  setup do
    {:ok, pid} = Postgrex.Notifications.start_link(Repo.config())
    for ch <- ~w(users_changed subscriptions_changed api_keys_changed api_key_vaults_changed vaults_changed),
        do: {:ok, _} = Postgrex.Notifications.listen(pid, ch)

    %{listener: pid}
  end

  test "vaults: change_seq-only update is silent; a rename notifies the user id" do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      # Insert a user + vault with raw SQL or the factory under unboxed_run,
      # then: UPDATE vaults SET change_seq = change_seq + 1 -> refute_receive
      # UPDATE vaults SET slug = 'x2' -> assert_receive {:notification, _, _, "vaults_changed", user_id}
      # finally DELETE the user (cascade) so the shared test DB stays clean.
    end)
  end

  # One test per channel: users (UPDATE suspended_at), subscriptions (INSERT),
  # api_keys (DELETE), api_key_vaults (INSERT). Each asserts the exact payload.
end
```

Write the five tests concretely (insert rows with `Repo.insert!` of the schema structs or `Repo.query!` raw SQL inside `unboxed_run`, which bypasses RLS as the test superuser). Use `assert_receive ..., 1_000` and `refute_receive ..., 300`.

- [ ] **Step 2: Run, verify failure** (no notifications).
- [ ] **Step 3: Write the migration**, one function + trigger per table, modeled on `20260612100000_notify_on_user_limit_override_change.exs` (`SET search_path = ''`, `RETURN COALESCE(NEW, OLD)`, `down` drops both). For vaults:

```sql
CREATE TRIGGER vaults_cache_notify
AFTER UPDATE ON vaults
FOR EACH ROW
WHEN ((to_jsonb(OLD) - 'change_seq' - 'updated_at') IS DISTINCT FROM (to_jsonb(NEW) - 'change_seq' - 'updated_at'))
EXECUTE FUNCTION notify_vaults_changed();
```

plus a separate `AFTER INSERT OR DELETE ON vaults` trigger on the same function. Read `docs/context/` migration linters doc and run the repo's migration linters locally (see `AGENTS.md` and `mix help | grep -i migration`) before committing.

- [ ] **Step 4: Run** the trigger test and `mise exec -- mix ecto.migrate` + `mix ecto.rollback --step 1` + migrate again on the `_qaudit` DB (`MIX_ENV=test MIX_TEST_PARTITION=_qaudit`). Expected: pass, reversible.
- [ ] **Step 5: Commit** `feat(db): NOTIFY triggers for cache eviction`.

---

### Task 5: Cache the per-request lookups

**Files:**
- Modify: `lib/engram/cache/registry.ex`, `lib/engram/accounts.ex` (`get_user/1` ~line 19, `validate_api_key/1` ~line 639), `lib/engram/billing.ex` (`get_subscription/1` ~line 426), `lib/engram/vaults.ex` (`list_vaults/1` ~287, `fetch_vault/2` ~600, `get_default_vault/1` ~618, `get_vault_by_ref/2` ~503 name/slug branch, `has_vault?/1` ~922, `accessible_vault_ids/1` ~873)
- Test: `test/engram/cache/request_lookups_test.exs`; lower budgets in `test/engram/query_budget_test.exs`

**Interfaces:**
- Consumes: `Engram.Cache.fetch/3`, `evict/2`; channels from Task 4.
- Registry entries:

| name | key | value | ttl | cache_nil | pg_channel |
|---|---|---|---|---|---|
| `:user` | user_id | `%User{}` with `subscription` NOT loaded | 60_000 | false | `users_changed` |
| `:api_key` | key_hash (same text form the trigger sends) | `%ApiKey{}` without `:user` preloaded | 30_000 | false | `api_keys_changed` |
| `:api_key_scope` | api_key_id | `:all` or `[vault_id]` | 30_000 | false | `api_key_vaults_changed` |
| `:subscription` | user_id | `%Subscription{}` or nil | 60_000 | true | `subscriptions_changed` |
| `:vaults` | user_id | list of active `%Vault{}` rows, decrypted | 60_000 | false | `vaults_changed` |

- Produces (signatures unchanged): `Accounts.get_user/1`, `Accounts.validate_api_key/1` (now: cached key -> cached user), `Billing.get_subscription/1`, `Vaults.list_vaults/1`, `get_vault/2`, `get_default_vault/1`, `get_vault_by_ref/2`, `has_vault?/1`, `accessible_vault_ids/1`. `get_vault`, `get_default_vault`, `has_vault?` and the slug/name branch of `get_vault_by_ref` now filter the cached `list_vaults/1` result in memory (a user has a handful of vaults).

- [ ] **Step 1: Lower budgets first (red).** In `query_budget_test.exs` subtract the preamble the audit showed (API key 6, subscription 5, vault resolution 5, api_key_vaults 1) from every authed path. Run: those paths fail.
- [ ] **Step 2: Write `test/engram/cache/request_lookups_test.exs`** (DataCase, async: false; clear the five caches in setup):
  - `get_user/1` hits the DB once across two calls (use `Engram.QueryRecorder.record/1`, count `source == "users"`), and a `{:notification, _, _, "users_changed", id}` sent to `Engram.Cache.Server` makes the next call reload (soft-delete the user in between with `Repo.update_all`, assert `deleted_at` is set on the reloaded struct).
  - `validate_api_key/1`: second call issues 0 queries; after `Accounts.revoke_api_key/2` plus the NOTIFY message for that key_hash, `validate_api_key/1` returns `{:error, :invalid_key}` ("revoked key stops resolving after eviction").
  - `get_subscription/1` caches nil (user with no subscription: second call 0 queries) and reloads after `subscriptions_changed`.
  - Vaults: `get_vault/2`, `get_default_vault/1` and `get_vault_by_ref/2` by slug issue 0 queries after one `list_vaults/1`; after `Vaults.delete_vault/2` plus the `vaults_changed` notification, `get_vault/2` returns `{:error, :not_found}` ("vault cache evicted on vaults UPDATE notification").
  - `accessible_vault_ids/1` caches per key id and reloads after `api_key_vaults_changed`.
  - RLS control: the loader for `:vaults` still runs under `Repo.with_tenant(user.id, ...)`; a test asserts another user's id never returns the first user's vaults.
- [ ] **Step 3: Implement.**
  - `Accounts.get_user/1`: `Engram.Cache.fetch(:user, id, fn -> Repo.get(User, id, skip_tenant_check: true) end)`. `get_user!/1` stays uncached (it raises; callers are admin paths). Check `fresh_user/1` in vaults.ex still behaves (it reloads when `encrypted_dek` is nil; keep it calling `Repo.get` directly so a DEK-less cached user cannot loop).
  - `validate_api_key/1`: `key = Engram.Cache.fetch(:api_key, key_hash, fn -> <today's role-switch transaction, WITHOUT the user preload> end)`; then `user = Accounts.get_user(key.user_id)`; return `{:ok, user, key}`. A nil user (deleted) returns `{:error, :invalid_key}`.
  - `Billing.get_subscription/1` (the `%{id: id}` clause): `Engram.Cache.fetch(:subscription, user.id, fn -> <today's with_tenant! query> end)`. The `user.subscription` already-loaded short-circuit (if present) stays first.
  - `Vaults.list_vaults/1`: `Engram.Cache.fetch(:vaults, user.id, fn -> <today's with_tenant query + decrypt> end)`. Rewrite `fetch_vault/2` as `Enum.find(list_vaults(user), &(&1.id == vault_id))`, `get_default_vault/1` as `Enum.find(..., & &1.is_default)`, `has_vault?/1` as `list_vaults(user) != []`, and the name/slug branch of `get_vault_by_ref/2` as an in-memory match on `slug` / `name_hmac` over the same list (keep the exact matching rules: read `resolve_name_ref/2` and port it to operate on the list; `slugify_ref/1` unchanged). Grep every reader of `vault.change_seq` on a struct from these functions (`grep -rn "change_seq" lib`); none may rely on it being fresh (it is excluded from the trigger). If one does, read the seq with `Vaults.current_seq/1` (or add it) instead.
  - `accessible_vault_ids/1`: `Engram.Cache.fetch(:api_key_scope, api_key.id, fn -> <today's query + :all fallback> end)`.
  - Every existing explicit eviction site that already exists for these rows (e.g. `GateCache.evict` in `delete_vault/2`, `SessionInvalidator.disconnect_user` in `revoke_api_key/2`) keeps working; additionally call `Engram.Cache.evict(:api_key, key.key_hash)` in `revoke_api_key/2` and `Engram.Cache.evict(:vaults, user.id)` at the end of `insert_vault`, `update_vault`, `delete_vault`, `restore_vault` so the writing node is coherent without waiting for the NOTIFY round trip.
- [ ] **Step 4: Run** the new test, `test/engram/query_budget_test.exs`, `test/engram/accounts*`, `test/engram/vaults*`, `test/engram/billing*`, `test/engram_web/plugs`, `test/engram_web/controllers/mcp_*`. Expected: pass; budgets met. Then the full suite once: `MIX_TEST_PARTITION=_qaudit mise exec -- mix test > /tmp/t5.txt 2>&1; echo $?`. Cached state leaking between tests is the likely failure: if a test mutates users/vaults/subscriptions with raw SQL and expects the next read to see it, clear the caches in `test/support/data_case.ex` and `conn_case.ex` setup (`for c <- [:user, :api_key, :api_key_scope, :subscription, :vaults], do: Engram.Cache.clear_local(c)`) rather than editing the assertions.
- [ ] **Step 5: Commit** `perf: cache user, key, subscription, vault lookups`.

---

### Task 6: One tenant transaction per MCP call and channel event

**Files:**
- Modify: `lib/engram/repo.ex` (`run_with_tenant/2` ~line 191), `lib/engram_web/controllers/mcp_controller.ex` (`run_tool_handler/4` ~line 907), `lib/engram_web/channels/crdt_channel.ex` (DB-touching `handle_in` clauses), `lib/engram/notes.ex` and any module that calls `Phoenix.PubSub.broadcast`, `EngramWeb.Endpoint.broadcast`, `CrdtDeliver.fanout*`, or `Notes.Enqueue.enqueue` from inside a write
- Test: `test/engram/repo_after_commit_test.exs`; lower budgets

**Interfaces:**
- Produces:
  - `Engram.Repo.after_commit((-> any())) :: :ok` : outside a tenant transaction runs `fun` now; inside, queues it and runs it after the OUTERMOST `with_tenant` transaction commits; dropped if that transaction rolls back or raises.
  - `Engram.Repo.after_tenant((-> any())) :: :ok` : inside a tenant transaction, queues `fun` to run inside the same transaction AFTER `tenant_exit` (role reset), before commit. Outside, runs now. Used for Oban inserts (`engram_app` has no grant on `oban_jobs`).
  - Queues live in the process dictionary under `:engram_after_commit` / `:engram_after_tenant`, set up only by the outermost `run_with_tenant/2`.

- [ ] **Step 1: Write the failing tests** (`test/engram/repo_after_commit_test.exs`, DataCase):

```elixir
test "after_commit runs after the outermost tenant transaction commits" do
  user = insert(:user)
  parent = self()

  {:ok, :done} =
    Repo.with_tenant(user.id, fn ->
      :ok = Repo.after_commit(fn -> send(parent, {:ran, Repo.in_transaction?()}) end)
      {:ok, :inner} = Repo.with_tenant(user.id, fn -> :inner end)
      refute_received {:ran, _}
      :done
    end)

  # In the SQL sandbox the outer with_tenant is a savepoint inside the test
  # transaction, so in_transaction? is true there; assert only ordering.
  assert_received {:ran, _}
end

test "after_commit callbacks dropped on rollback" do
  user = insert(:user)
  parent = self()

  assert_raise RuntimeError, fn ->
    Repo.with_tenant(user.id, fn ->
      :ok = Repo.after_commit(fn -> send(parent, :ran) end)
      raise "boom"
    end)
  end

  refute_received :ran
end

test "after_tenant runs inside the transaction with the tenant role reset" do
  user = insert(:user)
  parent = self()

  Repo.with_tenant(user.id, fn ->
    :ok =
      Repo.after_tenant(fn ->
        %{rows: [[role, tenant]]} =
          Repo.query!("SELECT current_setting('role'), current_setting('app.current_tenant', true)")

        send(parent, {:after_tenant, role, tenant})
      end)
  end)

  assert_received {:after_tenant, "none", ""}
end

test "outside a transaction both hooks run immediately" do
  parent = self()
  :ok = Repo.after_commit(fn -> send(parent, :now) end)
  assert_received :now
end
```

- [ ] **Step 2: Run, verify failure.**
- [ ] **Step 3: Implement in `repo.ex`.** In `run_with_tenant/2`, when this is the outermost block (`Process.get(:engram_after_commit) == nil` on entry), initialize both queues to `[]`. After `fun.()` returns and BEFORE the existing `tenant_exit` query, leave things as is; AFTER the `tenant_exit` query, run the `:engram_after_tenant` queue in order (still inside the transaction). After `transaction/2` returns `{:ok, _}`, run the `:engram_after_commit` queue in order. In the `after` clause, delete both keys (outermost only). Nested same-tenant calls take the re-entrant branch and never touch the queues. Keep the `source:` keywords.

```elixir
def after_commit(fun) when is_function(fun, 0) do
  case Process.get(:engram_after_commit) do
    nil -> _ = fun.(); :ok
    q -> Process.put(:engram_after_commit, q ++ [fun]); :ok
  end
end

def after_tenant(fun) when is_function(fun, 0) do
  case Process.get(:engram_after_tenant) do
    nil -> _ = fun.(); :ok
    q -> Process.put(:engram_after_tenant, q ++ [fun]); :ok
  end
end
```

- [ ] **Step 4: Move side effects.** In the write paths reached by MCP tools and CRDT channel events, wrap every broadcast / fanout / room notify in `Repo.after_commit/1`, and every `Notes.Enqueue.enqueue` / `Oban.insert` in `Repo.after_tenant/1`. `ContentCommit.after_commit/3` becomes: its three enqueues each go through `Repo.after_tenant/1`. Grep list to cover: `grep -rn "PubSub.broadcast\|Endpoint.broadcast\|fanout_idle\|fanout(\|Enqueue.enqueue\|Oban.insert" lib/engram/notes* lib/engram/notes lib/engram/mcp lib/engram_web/channels`. Every one of them reachable from a with_tenant body must be wrapped.
- [ ] **Step 5: Request scope.** In `McpController.run_tool_handler/4`, wrap the handler call: `{:ok, result} = Repo.with_tenant(user.id, fn -> <current body> end)` for every tool EXCEPT `search_notes` (and any other tool that calls Voyage, Qdrant or S3: grep `Engram.Vector|Voyage|Storage` reachable from `Handlers.handle/4`; list them in a `@no_request_txn` module attribute with a comment saying external I/O must not run inside a transaction). The response is sent by the controller after `run_tool_handler/4` returns, so it is sent after commit. Do the same in `CrdtChannel` for `handle_in` clauses that write (`crdt_msg`, `crdt_doc_update`, catchup reads): wrap the clause body in `Repo.with_tenant(socket.assigns.user_id ...)`; the reply is returned after the block, so after commit.
- [ ] **Step 6: Lower budgets** for MCP and CRDT paths by the tenant overhead the audit attributes to blocks now merged (each removed block = 4). Run budget test, the new repo test, `test/engram/notes*`, `test/engram/mcp`, `test/engram_web/channels`, `test/engram_web/controllers/mcp_*`. Then the full suite. Expected: pass.
- [ ] **Step 7: Commit** `perf: one tenant transaction per MCP call`.

---

### Task 7: Write path reads the note once

**Files:**
- Modify: `lib/engram/mcp/handlers.ex` (`handle("append_to_note", ...)` ~423, `rmw_upsert`, `do_patch_text` ~908, `replace_section` path ~988, edit helpers ~1109), `lib/engram/notes.ex` (`upsert_note/4` ~440-500, `lookup_and_write/2` ~1970, `maybe_merge_crdt/6` ~2259, `authoritative_content/2`, `get_note/3` ~2295), `lib/engram/notes/crdt_persistence.ex` (`tail_rows/2` ~348, `warn_on_foreign_vault_rows/3` ~368), `lib/engram/notes/crdt_deliver.ex` (`fanout_idle/3` ~124, `load_merged_state/2` ~337, `read_merged_state/2` ~366)
- Test: `test/engram/mcp/handlers_single_read_test.exs`; lower budgets

**Interfaces:**
- Produces: `Engram.Notes.get_note_for_update(user, vault, path) :: {:ok, Note.t()} | {:error, :not_found}` (row locked `FOR UPDATE` inside the caller's tenant transaction; raises if called outside one). `upsert_note/4` accepts `opts[:locked_note]` (a note row already locked in this transaction) and then skips its own lookup.

- [ ] **Step 1: Write the failing tests:**
  - "append reads the note once": `QueryRecorder.record(fn -> call_tool(conn, "append_to_note", ...) end)`; assert exactly one query with `source == "notes"` and SQL starting `SELECT`, and at most one `crdt_update_log` SELECT, and zero `SELECT count(*) FROM "crdt_update_log"`.
  - "concurrent appends both land": two `Task.async` calls of the append tool on the same note with different texts (sandbox in shared mode: `Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})`), then `get_notes` contains both texts.
  - "fanout does not re-read the note": record a write; assert no `users` query and no `notes` SELECT after the UPDATE.
- [ ] **Step 2: Run, verify failure.**
- [ ] **Step 3: Implement.**
  - append/edit/patch/replace_section: inside the request transaction (Task 6), call `Notes.get_note_for_update/3` once, compute the new content from `Notes.authoritative_content/2` of THAT row (one tail replay), call `upsert_note(..., locked_note: note)`. Delete the existence pre-check and the CAS retry loop in `rmw_upsert` (the row lock serializes writers); keep the not-found branch that creates the note.
  - `lookup_and_write/2`: when `opts[:locked_note]` is present, use it instead of running `lookup_query`, and pass the already-replayed merged text to `maybe_merge_crdt/6` instead of replaying the tail again (thread it through as an argument; do not stash it in the process dictionary).
  - `CrdtPersistence.tail_rows/2`: select `vault_id` with the tail rows and run the foreign-vault check in memory over the returned rows; delete the separate `count(*)` query. Keep the warning log and its message text (e2e may assert on it; grep `backend/e2e` and `frontend/e2e` for the string before changing anything).
  - `CrdtDeliver.fanout_idle/3`: accept the committed note (and its merged state) from the write site through `Repo.after_commit/1`'s closure; delete the `users` re-read and the notes re-read on that path. Other callers of `load_merged_state/2` keep the read.
- [ ] **Step 4: Lower budgets** (append/edit/write/POST append/CRDT update) and run the budget test, new tests, `test/engram/notes*`, `test/engram/mcp`, e2e-relevant channel tests, then the full suite.
- [ ] **Step 5: Commit** `perf: write path reads the note once`.

---

### Task 8: OriginStats buffered

**Files:**
- Modify: `lib/engram/abuse/origin_stats.ex` (~lines 41-65), `lib/engram/application.ex`, `lib/engram/cache/registry.ex` only if you reuse a table (prefer a dedicated counter table owned by a small `OriginStats.Buffer` GenServer: counters are not a cache)
- Test: `test/engram/abuse/origin_stats_test.exs` (extend)

**Interfaces:**
- Produces: `Engram.Abuse.OriginStats.record/2` (unchanged signature) increments an ETS counter keyed by today's `{day, user_id, <existing dimensions>}` and returns `:ok` with zero queries; `Engram.Abuse.OriginStats.flush/0` writes all counters with ONE `insert_all ... on_conflict: [inc: ...]` and resets them; the buffer process calls `flush/0` every 30 s and on `terminate/2` (trap exits).

- [ ] **Step 1: Failing tests:** `record/2` issues 0 queries (QueryRecorder); after `flush/0` the row holds the summed count; two `record/2` calls then one `flush/0` issue exactly 1 query; `flush/0` with no counters issues 0 queries.
- [ ] **Step 2-3:** Run red; implement with `:ets.update_counter(table, key, {2, 1}, {key, 0})`, flush via `:ets.take/2` per key (atomic read-and-delete) or `:ets.select_delete` after reading. Rescue + log on flush DB errors exactly like today's `record/2` rescue (never crash the buffer). Start the buffer in `application.ex`.
- [ ] **Step 4:** Lower the MCP budgets by 1; run budget + origin stats tests.
- [ ] **Step 5: Commit** `perf: buffer origin stats, flush every 30s`.

---

### Task 9: `envelope_open_many` NIF + search spans

**Files:**
- Modify: `native/engram_native/src/` (the envelope NIF module; find with `grep -rn "envelope_open" native/engram_native/src`), `lib/engram/native.ex`, `lib/engram/crypto/envelope.ex` (`decrypt` path), multi-note readers: `Notes` decrypt of a list (`decrypt_or_raise!` over lists in get_notes / tree / search hydrate; find with `grep -rn "Enum.map(.*decrypt" lib/engram/notes*`), search: the Voyage embed call and the Qdrant query call (`lib/engram/vector/qdrant.ex`, `lib/engram/embedders/voyage.ex` or equivalents)
- Test: `test/engram/crypto/envelope_open_many_test.exs`, Rust unit test in the crate; benchmark entry in `docs/context/native-nifs.md`

**Interfaces:**
- Produces: `Engram.Crypto.Envelope.decrypt_many([{ciphertext, nonce, aad}], key) :: [{:ok, binary()} | :error]` with the same per-item results as mapping `decrypt/…` (exact function name/arity: mirror the existing single decrypt in envelope.ex). One dirty-scheduler call for the whole list when any item is format 1; format-0-only lists stay inline as today.

- [ ] **Step 1: Failing tests:** property test (StreamData) that `decrypt_many(items)` equals `Enum.map(items, &decrypt/…)` for mixed format 0 / format 1 / tampered items (tampered -> `:error`, never a raise); empty list -> `[]`.
- [ ] **Step 2: Measure first.** Benchmark today's per-item decrypt over 20 notes x (content + 5 metadata fields) with `Benchee` or `:timer.tc` (min of 5) on the dev box. Record the number.
- [ ] **Step 3: Implement** the Rust function (reuse `engram_core`'s open; loop; return a list of `{:ok, binary} | :error`), wire `Engram.Native`, then `Envelope.decrypt_many/2`, then switch the multi-note readers.
- [ ] **Step 4: Measure again.** If the batch is not faster by at least 20% on the 20-note case, revert the reader switch and the NIF (keep nothing) and record the measurement and the decision in the ledger and `docs/context/native-nifs.md`. If faster, keep and record before/after in `docs/context/native-nifs.md`.
- [ ] **Step 5: Search spans:** wrap the Voyage embed call and the Qdrant query in `OpenTelemetry.Tracer.with_span "voyage.embed"` / `"qdrant.query"` (see how existing manual spans are made: `grep -rn "Tracer.with_span" lib`). Test: an existing search test still passes; no assertion on spans needed beyond compile.
- [ ] **Step 6: Commit** `perf(nif): batch envelope opens` (or `docs: record envelope_open_many result` if reverted) and `feat(obs): trace voyage and qdrant calls`.

---

### Task 10: Final budgets, full gates, docs

**Files:**
- Modify: `test/engram/query_budget_test.exs` (final numbers), `.sobelow-skips` (if lines moved)
- Create: `docs/context/request-query-budget.md`
- Modify: `AGENTS.md` / `CLAUDE.md` context-doc index in the backend repo if it lists docs/context entries

- [ ] **Step 1:** Set `@budgets` to the spec §7 targets: reads (mcp get_notes, GET notes/*path, GET folders, GET tags) 5; manifest 6; bootstrap 8; write_note / POST notes / append / edit / POST append 12; rename and CRDT update / doc_update 16. Run. For any path still above target, read its query list (printed on failure) and remove the remaining redundant queries (cache hit missing, an extra with_tenant block, a duplicate read). If a path cannot reach its target without removing a query that carries a real guarantee (revision rows, unique-job check, vault seq), set its budget to the measured floor, and write the remaining queries and why each is required into the test as a comment. Never raise a budget above Task 1's pinned number.
- [ ] **Step 2:** Full gates: `MIX_TEST_PARTITION=_qaudit mise exec -- mix test > /tmp/full.txt 2>&1; echo $?`, `mise exec -- mix dialyzer > /tmp/dia.txt 2>&1; echo $?`, `mise exec -- mix credo --strict`, `mise exec -- mix format --check-formatted`, `mise exec -- mix sobelow` (regenerate skips per Global Constraints if needed), cargo tests for the NIF crate if touched.
- [ ] **Step 3:** Write `docs/context/request-query-budget.md`: the measured before/after table; how `Engram.Cache` works (registry, TTL as backstop, trigger NOTIFY eviction, cluster eviction, how to add a cache in 3 steps); `Repo.after_commit` / `after_tenant` rules (no external I/O in a tenant transaction; Oban inserts via after_tenant because engram_app has no oban_jobs grant); the budget test and how to read its failure output. No em dashes. Add a one-line routing entry wherever the backend repo indexes docs/context.
- [ ] **Step 4: Commit** `test: enforce final query budgets` and `docs(context): request query budget + cache`.
