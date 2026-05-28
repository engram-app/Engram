defmodule Engram.Crypto.DekCacheTest do
  use ExUnit.Case, async: false
  alias Engram.Crypto.DekCache

  setup do
    DekCache.invalidate_all()
    :ok
  end

  @dek :binary.copy(<<0xAA>>, 32)

  test "put + get round-trip" do
    DekCache.put(1, @dek)
    assert {:ok, @dek} = DekCache.get(1)
  end

  test "miss returns :miss" do
    assert :miss = DekCache.get(404)
  end

  test "invalidate removes entry" do
    DekCache.put(1, @dek)
    DekCache.invalidate(1)
    assert :miss = DekCache.get(1)
  end

  test "invalidate_all clears everything" do
    DekCache.put(1, @dek)
    DekCache.put(2, @dek)
    DekCache.invalidate_all()
    assert :miss = DekCache.get(1)
    assert :miss = DekCache.get(2)
  end

  test "entries expire after TTL" do
    DekCache.put(1, @dek, _ttl_ms = 10)
    Process.sleep(25)
    DekCache.sweep_now()
    assert :miss = DekCache.get(1)
  end

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

    test "ignores a foreign cache_sync message (VersionCache's) without crashing" do
      pid = Process.whereis(Engram.Crypto.DekCache)
      DekCache.put(50, @dek)

      CacheSync.broadcast(:version_evict_all)
      _ = DekCache.sensitive_flag?()

      assert Process.alive?(pid)
      assert {:ok, @dek} = DekCache.get(50)
    end
  end

  describe "real two-node eviction" do
    @tag :cluster
    test "invalidate on node A evicts the entry cached on node B" do
      {peer_pid, _peer_node} =
        Engram.ClusterCase.start_peer!([Engram.Crypto.DekCache], &on_exit/1)

      DekCache.put(123, @dek)
      :ok = :peer.call(peer_pid, Engram.Crypto.DekCache, :put, [123, @dek, nil])
      assert {:ok, @dek} = :peer.call(peer_pid, Engram.Crypto.DekCache, :get, [123])

      DekCache.invalidate(123)

      assert eventually(fn ->
               :miss == :peer.call(peer_pid, Engram.Crypto.DekCache, :get, [123])
             end)
    end

    @tag :cluster
    test "invalidate_all on node A evicts all entries cached on node B" do
      {peer_pid, _peer_node} =
        Engram.ClusterCase.start_peer!([Engram.Crypto.DekCache], &on_exit/1)

      for id <- [1, 2] do
        DekCache.put(id, @dek)
        :ok = :peer.call(peer_pid, Engram.Crypto.DekCache, :put, [id, @dek, nil])
      end

      assert {:ok, @dek} = :peer.call(peer_pid, Engram.Crypto.DekCache, :get, [1])

      DekCache.invalidate_all()

      assert eventually(fn ->
               :miss == :peer.call(peer_pid, Engram.Crypto.DekCache, :get, [1]) and
                 :miss == :peer.call(peer_pid, Engram.Crypto.DekCache, :get, [2])
             end)
    end
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() ->
        true

      attempts <= 0 ->
        false

      true ->
        Process.sleep(20)
        eventually(fun, attempts - 1)
    end
  end

  describe "T3.3 / H2 — ETS write protection" do
    @table :engram_dek_cache

    test "ETS table is :protected (foreign-process write raises)" do
      # Pre-fix: table was :public, so any process could `:ets.insert` and
      # poison-replace a victim's DEK. Post-fix: only the DekCache GenServer
      # can write; foreign-process attempts must raise ArgumentError.
      attacker_dek = :binary.copy(<<0xFF>>, 32)
      now = :erlang.system_time(:millisecond)

      assert_raise ArgumentError, fn ->
        :ets.insert(@table, {99_999, attacker_dek, now + 60_000})
      end
    end

    test "ETS table is :protected (foreign-process delete raises)" do
      DekCache.put(1, @dek)

      assert_raise ArgumentError, fn ->
        :ets.delete(@table, 1)
      end

      # Sanity: legitimate API still works.
      assert {:ok, @dek} = DekCache.get(1)
    end

    test "DekCache GenServer process has :sensitive flag set (M9 — exclude from crash dump)" do
      # `process_info(pid, :sensitive)` is not a valid introspection key on
      # current OTP. We round-trip through the GenServer instead: the helper
      # asks the process to read its own flag (process_flag/2 returns the
      # previous value, so toggling true→true is a non-mutating read).
      assert true == DekCache.sensitive_flag?()
    end
  end
end
