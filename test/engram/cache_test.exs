defmodule Engram.CacheTest do
  use ExUnit.Case, async: false

  alias Engram.Cache

  setup do
    Cache.clear_local(:test_cache)
    Cache.clear_local(:test_cache_nil)
    Cache.clear_local(:test_cache_pairs)
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
end
