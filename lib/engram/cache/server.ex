defmodule Engram.Cache.Server do
  @moduledoc "Owns every `Engram.Cache` table; applies cluster and Postgres evictions; sweeps expired rows."
  use GenServer

  alias Engram.Cache
  alias Engram.Cache.Registry

  @sweep_ms 60_000

  @legacy_evict %{
    billing_entitlement_evict: :billing_entitlement,
    billing_override_evict: :billing_override,
    onboarding_gate_evict: :onboarding_gate
  }
  # The old GateCache also cleared on :version_evict_all (a raised floor).
  @legacy_evict_all %{
    billing_entitlement_evict_all: [:billing_entitlement],
    billing_override_evict_all: [:billing_override],
    version_evict_all: [:legal_version, :onboarding_gate]
  }

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    # Tables back user data (vault names, users rows): keep them out of crash dumps.
    _ = Process.flag(:sensitive, true)

    for %{name: name} <- Registry.caches() do
      _ =
        :ets.new(Registry.table(name), [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])
    end

    :ok = Engram.Cluster.CacheSync.subscribe()
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, %{channels: channel_map()}}
  end

  # channel => [{cache, :key | :all}]. `Engram.Cache.Listener` owns the LISTEN
  # connection and forwards notifications here.
  defp channel_map do
    for spec <- Registry.caches(),
        {channel, how} <- [{spec.pg_channel, :key}, {Map.get(spec, :pg_clear_channel), :all}],
        channel != nil,
        reduce: %{} do
      acc -> Map.update(acc, channel, [{spec.name, how}], &[{spec.name, how} | &1])
    end
  end

  @impl true
  def handle_info(:pg_listen_connected, state) do
    # Anything committed while the LISTEN connection was down never notified
    # this node, so nothing it cached is known fresh.
    for {_channel, targets} <- state.channels, {cache, _} <- targets, do: Cache.clear_local(cache)

    {:noreply, state}
  end

  @impl true
  def handle_info({:notification, _pid, _ref, channel, payload}, state) do
    for {cache, how} <- Map.get(state.channels, channel, []) do
      case how do
        :key -> Cache.evict_local(cache, payload)
        :all -> Cache.clear_local(cache)
      end
    end

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

  # Shapes the pre-Engram.Cache caches broadcast. A node still on that
  # release sends them during a rolling deploy; dropped, a Paddle webhook
  # handled there left the new nodes' entitlement stale for up to 24 h.
  # ponytail: delete once no node runs the release before this branch.
  def handle_info({:cache_sync, {tag, user_id}}, state) when is_map_key(@legacy_evict, tag) do
    :ok = Cache.evict_local(Map.fetch!(@legacy_evict, tag), user_id)
    {:noreply, state}
  end

  def handle_info({:cache_sync, tag}, state) when is_map_key(@legacy_evict_all, tag) do
    for cache <- Map.fetch!(@legacy_evict_all, tag), do: :ok = Cache.clear_local(cache)
    {:noreply, state}
  end

  def handle_info({:cache_sync, _other}, state), do: {:noreply, state}

  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    for %{name: name} <- Registry.caches() do
      # Delete rows whose expiry is an integer below now (:infinity rows are atoms and never match).
      :ets.select_delete(Registry.table(name), [
        {{:_, :_, :"$1"}, [{:is_integer, :"$1"}, {:<, :"$1", now}], [true]}
      ])
    end

    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end
end
