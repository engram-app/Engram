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

  describe "telemetry" do
    test "get/1 emits hit and miss outcomes" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :crypto, :dek_cache]])

      assert :miss = DekCache.get(999_001)
      assert_receive {[:engram, :crypto, :dek_cache], ^ref, %{count: 1}, %{outcome: :miss}}

      DekCache.put(999_001, @dek)
      assert {:ok, _} = DekCache.get(999_001)
      assert_receive {[:engram, :crypto, :dek_cache], ^ref, %{count: 1}, %{outcome: :hit}}
    end

    test "expired entry counts as miss" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :crypto, :dek_cache]])

      DekCache.put(999_002, @dek, _ttl_ms = 1)
      Process.sleep(10)
      assert :miss = DekCache.get(999_002)
      assert_receive {[:engram, :crypto, :dek_cache], ^ref, %{count: 1}, %{outcome: :miss}}
    end
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

  # get_dek's miss path: claim the slot, unwrap, store only if the claim is
  # still there. An invalidate in between (a DEK flip, local or from a peer)
  # deletes the claim, so a DEK loaded across the flip is never cached.
  describe "claim / put_if_claimed" do
    test "a claimed slot reads as a miss, and the claimer's put stores" do
      token = DekCache.claim(1)
      assert :miss = DekCache.get(1)
      assert :ok = DekCache.put_if_claimed(1, token, @dek)
      assert {:ok, @dek} = DekCache.get(1)
    end

    test "an invalidate between claim and store leaves the slot a miss" do
      token = DekCache.claim(1)
      DekCache.invalidate(1)
      assert :stale = DekCache.put_if_claimed(1, token, @dek)
      assert :miss = DekCache.get(1)
    end

    test "a peer dek_evict between claim and store leaves the slot a miss" do
      token = DekCache.claim(1)
      send(DekCache, {:cache_sync, {:dek_evict, 1}})
      assert :stale = DekCache.put_if_claimed(1, token, @dek)
      assert :miss = DekCache.get(1)
    end

    test "a newer claim wins over an older one" do
      old = DekCache.claim(1)
      new = DekCache.claim(1)
      assert :stale = DekCache.put_if_claimed(1, old, @dek)
      assert :ok = DekCache.put_if_claimed(1, new, @dek)
    end
  end

  # Single flight: while one loader holds the claim, other callers wait for its
  # DEK instead of each unwrapping (one KMS Decrypt per caller before).
  describe "claim_or_await/1" do
    test "a free slot is claimed; a cached DEK is returned" do
      assert {:claimed, token} = DekCache.claim_or_await(1)
      assert :ok = DekCache.put_if_claimed(1, token, @dek)
      assert {:ok, @dek} = DekCache.claim_or_await(1)
    end

    test "a waiter gets the loader's DEK without claiming" do
      {:claimed, token} = DekCache.claim_or_await(1)
      waiter = park_waiter(1)

      assert :ok = DekCache.put_if_claimed(1, token, @dek)
      assert {:ok, @dek} = Task.await(waiter)
    end

    test "a waiter gets the loader's error when the loader releases with one" do
      {:claimed, token} = DekCache.claim_or_await(1)
      waiter = park_waiter(1)

      assert :ok = DekCache.release(1, token, :kms_throttled)
      assert {:error, :kms_throttled} = Task.await(waiter)
      assert :miss = DekCache.get(1)
    end

    test "a release of a replaced claim does not fail the new loader's waiters" do
      {:claimed, old} = DekCache.claim_or_await(1)
      new = DekCache.claim(1)
      waiter = park_waiter(1)

      assert :ok = DekCache.release(1, old, :kms_throttled)
      refute Task.yield(waiter, 0)
      assert :ok = DekCache.put_if_claimed(1, new, @dek)
      assert {:ok, @dek} = Task.await(waiter)
    end

    test "a waiter retries when the slot is invalidated mid-load" do
      {:claimed, token} = DekCache.claim_or_await(1)
      waiter = park_waiter(1)

      DekCache.invalidate(1)
      assert :retry = Task.await(waiter)
      assert :stale = DekCache.put_if_claimed(1, token, @dek)
    end

    test "a waiter retries when a peer dek_evict lands mid-load" do
      {:claimed, _token} = DekCache.claim_or_await(1)
      waiter = park_waiter(1)

      send(DekCache, {:cache_sync, {:dek_evict, 1}})
      assert :retry = Task.await(waiter)
    end

    test "a waiter retries and the slot clears when the loader dies" do
      loader = hold_claim(1, &DekCache.claim_or_await/1)
      waiter = park_waiter(1)

      Process.exit(loader, :kill)
      assert :retry = Task.await(waiter)
      assert {:claimed, _} = DekCache.claim_or_await(1)
    end

    test "a claim/1 loader is monitored too" do
      loader = hold_claim(1, &DekCache.claim/1)
      waiter = park_waiter(1)

      Process.exit(loader, :kill)
      assert :retry = Task.await(waiter)
    end

    test "the loader asking again claims over instead of waiting on itself" do
      {:claimed, old} = DekCache.claim_or_await(1)
      assert {:claimed, new} = DekCache.claim_or_await(1)
      assert new != old
    end

    # Every waiter parked on one stalled loader times out at about the same
    # moment. Claiming over on timeout made them each replace the last one's
    # claim and each call KMS: the herd single flight exists to stop.
    test "waiters past the await budget fail instead of claiming over" do
      :ok = Engram.ServiceConfig.put_override(:dek_await_ms, 50)
      {:claimed, token} = DekCache.claim_or_await(1)

      waiters = for _ <- 1..3, do: Task.async(fn -> DekCache.claim_or_await(1) end)

      assert [{:error, :dek_load_timeout}] = waiters |> Task.await_many() |> Enum.uniq()
      # The stalled loader still holds the slot and can still fill it.
      assert :ok = DekCache.put_if_claimed(1, token, @dek)
      assert {:ok, @dek} = DekCache.get(1)
    end

    test "a served waiter emits outcome :coalesced" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :crypto, :dek_cache]])
      {:claimed, token} = DekCache.claim_or_await(1)
      waiter = park_waiter(1)

      :ok = DekCache.put_if_claimed(1, token, @dek)
      {:ok, @dek} = Task.await(waiter)
      assert_receive {[:engram, :crypto, :dek_cache], ^ref, %{count: 1}, %{outcome: :coalesced}}
    end

    # The waiter shared the loader's one failed unwrap; counting it keeps
    # `miss - coalesced` equal to unwrap attempts during a KMS failure burst.
    test "a waiter served the loader's error emits outcome :coalesced" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :crypto, :dek_cache]])
      {:claimed, token} = DekCache.claim_or_await(1)
      waiter = park_waiter(1)

      :ok = DekCache.release(1, token, :kms_throttled)
      {:error, :kms_throttled} = Task.await(waiter)
      assert_receive {[:engram, :crypto, :dek_cache], ^ref, %{count: 1}, %{outcome: :coalesced}}
    end

    test "a waiter woken with :retry does not emit :coalesced" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :crypto, :dek_cache]])
      {:claimed, _token} = DekCache.claim_or_await(1)
      waiter = park_waiter(1)

      DekCache.invalidate(1)
      :retry = Task.await(waiter)
      refute_receive {[:engram, :crypto, :dek_cache], ^ref, _, %{outcome: :coalesced}}
    end

    test "a DEK found by claim_or_await itself emits outcome :coalesced" do
      DekCache.put(1, @dek)
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :crypto, :dek_cache]])

      {:ok, @dek} = DekCache.claim_or_await(1)
      assert_receive {[:engram, :crypto, :dek_cache], ^ref, %{count: 1}, %{outcome: :coalesced}}
    end
  end

  # A task parked on user_id's claim; returns once the owner holds it as a waiter.
  defp park_waiter(user_id) do
    before = waiter_count(user_id)
    task = Task.async(fn -> DekCache.claim_or_await(user_id) end)
    await(fn -> waiter_count(user_id) > before end)
    task
  end

  # A process that claims user_id via `claim_fun` and holds it until killed.
  defp hold_claim(user_id, claim_fun) do
    test = self()

    pid =
      spawn(fn ->
        claim_fun.(user_id)
        send(test, {:holding, self()})
        Process.sleep(:infinity)
      end)

    assert_receive {:holding, ^pid}
    pid
  end

  defp waiter_count(user_id),
    do: :sys.get_state(DekCache).waiters |> Map.get(user_id, []) |> length()

  defp await(fun, tries \\ 500) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never held")

      true ->
        Process.sleep(1)
        await(fun, tries - 1)
    end
  end
end
