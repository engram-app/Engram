defmodule Engram.CacheTest do
  use ExUnit.Case, async: false

  alias Engram.Cache

  setup do
    Cache.clear_local(:test_cache)
    Cache.clear_local(:test_cache_nil)
    Cache.clear_local(:test_cache_pairs)
    Cache.clear_local(:test_cache_forever)
    :ok
  end

  test "fetch runs the loader once and serves the cached value" do
    counter = :counters.new(1, [])

    load = fn ->
      :counters.add(counter, 1, 1)
      :value
    end

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

  test "evict does not echo back and drop a value re-cached after it" do
    :ok = Cache.evict(:test_cache_forever, :k)
    Cache.put(:test_cache_forever, :k, :fresh)
    _ = :sys.get_state(Engram.Cache.Server)
    assert Cache.get(:test_cache_forever, :k) == {:ok, :fresh}
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
    assert Cache.get(:test_cache_pairs, {"u1", :b}) == :miss
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

  test "an eviction during the loader leaves the key a miss" do
    # The loader evicts its own key, standing in for a NOTIFY that lands
    # between the DB read and the put: the stale value must not be stored.
    assert Cache.fetch(:test_cache, :k, fn ->
             :ok = Cache.evict_local(:test_cache, :k)
             :stale
           end) == :stale

    assert Cache.get(:test_cache, :k) == :miss
    assert Cache.fetch(:test_cache, :k, fn -> :fresh end) == :fresh
    assert Cache.get(:test_cache, :k) == {:ok, :fresh}
  end

  test "a clear during the loader leaves the key a miss" do
    Cache.fetch(:test_cache, :k, fn ->
      :ok = Cache.clear_local(:test_cache)
      :stale
    end)

    assert Cache.get(:test_cache, :k) == :miss
  end

  test "a first_elem eviction during the loader leaves the pair key a miss" do
    Cache.fetch(:test_cache_pairs, {"u1", :a}, fn ->
      :ok = Cache.evict_local(:test_cache_pairs, "u1")
      :stale
    end)

    assert Cache.get(:test_cache_pairs, {"u1", :a}) == :miss
  end

  test "evicting another key during the loader still caches" do
    Cache.fetch(:test_cache, :k, fn ->
      :ok = Cache.evict_local(:test_cache, :other)
      :v
    end)

    assert Cache.get(:test_cache, :k) == {:ok, :v}
  end

  test "a raising loader leaves the key a miss" do
    assert_raise RuntimeError, fn -> Cache.fetch(:test_cache, :k, fn -> raise "boom" end) end
    assert Cache.get(:test_cache, :k) == :miss
  end

  test "evict_all clears the cache and broadcasts" do
    :ok = Engram.Cluster.CacheSync.subscribe()
    Cache.put(:test_cache, :a, 1)
    Cache.put(:test_cache, :b, 2)
    :ok = Cache.evict_all(:test_cache)
    assert Cache.get(:test_cache, :a) == :miss
    assert Cache.get(:test_cache, :b) == :miss
    assert_receive {:cache_sync, {:engram_cache_evict_all, :test_cache}}
  end

  test "an :infinity row survives a sweep" do
    Cache.put(:test_cache_forever, :k, 1)
    send(Engram.Cache.Server, :sweep)
    _ = :sys.get_state(Engram.Cache.Server)
    assert Cache.get(:test_cache_forever, :k) == {:ok, 1}
  end

  test "a LISTEN (re)connect clears every NOTIFY-evicted cache, and only those" do
    Cache.put(:test_cache, "k", 1)
    Cache.put(:test_cache_forever, :k, 1)
    send(Engram.Cache.Server, :pg_listen_connected)
    _ = :sys.get_state(Engram.Cache.Server)
    assert Cache.get(:test_cache, "k") == :miss
    assert Cache.get(:test_cache_forever, :k) == {:ok, 1}
  end

  describe "Engram.Cache.Listener" do
    alias Engram.Cache.Listener

    test "LISTENs on every registry channel when it connects" do
      {:ok, state} = Listener.init(:ok)
      {:query, sql, state} = Listener.handle_connect(state)
      assert sql =~ ~s(LISTEN "test_cache_changed")
      assert sql =~ ~s(LISTEN "api_key_vaults_changed")
      assert state.listening
    end

    test "tells the server once the LISTEN is in place, then forwards notifications" do
      Process.register(self(), :listener_probe)
      {:ok, state} = Listener.init(server: :listener_probe)
      {:query, _, state} = Listener.handle_connect(state)
      {:noreply, _} = Listener.handle_result([], state)
      assert_receive :pg_listen_connected

      :ok = Listener.notify("users_changed", "u1", state)
      assert_receive {:notification, _, _, "users_changed", "u1"}
    end

    test "a failed LISTEN is logged, not reported as connected, and retried" do
      Process.register(self(), :listener_probe_err)
      {:ok, state} = Listener.init(server: :listener_probe_err, retry_ms: 10)
      {:query, _, state} = Listener.handle_connect(state)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:noreply, state} =
                   Listener.handle_result(%Postgrex.Error{message: "boom"}, state)

          send(self(), {:state, state})
        end)

      assert log =~ "cache: failed to LISTEN"
      refute_received :pg_listen_connected
      assert_received {:state, state}
      assert_receive :relisten, 500
      assert {:query, sql, _} = Listener.handle_info(:relisten, state)
      assert sql =~ "LISTEN"
    end

    test "rejects calls it does not handle" do
      {:ok, state} = Listener.init(:ok)
      ref = make_ref()
      # SimpleConnection hands callbacks {caller_pid, gen_statem_from}.
      {:noreply, _} = Listener.handle_call(:listen, {self(), {self(), ref}}, state)
      assert_receive {^ref, {:error, :unsupported}}
    end
  end
end
