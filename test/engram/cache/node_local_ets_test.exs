defmodule Engram.Cache.NodeLocalEtsTest do
  # Direct tests for the `use Engram.Cache.NodeLocalEts` scaffolding itself,
  # via throwaway cache modules. The real cache modules cover their own
  # semantics; this pins the macro's contract — guarded degradation on an
  # absent table, TTL rows, and the delete_local/1 override seam.
  use ExUnit.Case, async: true

  defmodule TtlCache do
    use Engram.Cache.NodeLocalEts, table: :nle_test_ttl_cache, ttl: 50
  end

  defmodule OverridingCache do
    use Engram.Cache.NodeLocalEts, table: :nle_test_overriding_cache, ttl: 60_000

    # Storage key is {user_id, subkey}; eviction key is just user_id — the
    # same shape OverrideCache uses in production.
    def delete_local(user_id) do
      :ets.match_delete(:nle_test_overriding_cache, {{user_id, :_}, :_, :_})
    rescue
      ArgumentError -> true
    end
  end

  # Never started — its table never exists, exercising the rescue guards.
  defmodule DeadCache do
    use Engram.Cache.NodeLocalEts, table: :nle_test_dead_cache, ttl: 50
  end

  describe "TTL primitives" do
    setup do
      start_supervised!(TtlCache)
      :ok
    end

    test "cache_put/cache_lookup round-trips within the TTL" do
      assert TtlCache.cache_put(:k, %{v: 1}) == :ok
      assert TtlCache.cache_lookup(:k) == {:ok, %{v: 1}}
    end

    test "cache_lookup returns :stale after the TTL elapses" do
      TtlCache.cache_put(:expiring, :v)
      Process.sleep(60)
      assert TtlCache.cache_lookup(:expiring) == :stale
    end

    test "cache_lookup on a missing key is :stale" do
      assert TtlCache.cache_lookup(:never_written) == :stale
    end

    test "cache_fetch computes on miss, then serves the cached value" do
      counter = :counters.new(1, [])

      loader = fn ->
        :counters.add(counter, 1, 1)
        :loaded
      end

      assert TtlCache.cache_fetch(:fetched, loader) == :loaded
      assert TtlCache.cache_fetch(:fetched, loader) == :loaded
      assert :counters.get(counter, 1) == 1
    end

    test "clear_local/0 drops every entry" do
      TtlCache.cache_put(:a, 1)
      TtlCache.cache_put(:b, 2)
      TtlCache.clear_local()
      assert TtlCache.cache_lookup(:a) == :stale
      assert TtlCache.cache_lookup(:b) == :stale
    end

    test "delete_local/1 drops only the given key" do
      TtlCache.cache_put(:keep, 1)
      TtlCache.cache_put(:drop, 2)
      TtlCache.delete_local(:drop)
      assert TtlCache.cache_lookup(:drop) == :stale
      assert TtlCache.cache_lookup(:keep) == {:ok, 1}
    end
  end

  describe "delete_local/1 override" do
    test "evicts by user while other users' entries survive" do
      start_supervised!(OverridingCache)

      OverridingCache.cache_put({:u1, :a}, 1)
      OverridingCache.cache_put({:u1, :b}, 2)
      OverridingCache.cache_put({:u2, :a}, 3)

      OverridingCache.delete_local(:u1)

      assert OverridingCache.cache_lookup({:u1, :a}) == :stale
      assert OverridingCache.cache_lookup({:u1, :b}) == :stale
      assert OverridingCache.cache_lookup({:u2, :a}) == {:ok, 3}
    end
  end

  describe "absent table (cache process down)" do
    test "every primitive degrades instead of crashing the caller" do
      assert DeadCache.ets_lookup(:k) == []
      assert DeadCache.ets_insert({:k, :v}) == :ok
      assert DeadCache.cache_lookup(:k) == :stale
      assert DeadCache.cache_put(:k, :v) == :ok
      assert DeadCache.cache_fetch(:k, fn -> :from_source end) == :from_source
      assert DeadCache.delete_local(:k) == true
      assert DeadCache.clear_local() == true
    end
  end
end
