defmodule Engram.Cache.Server do
  @moduledoc "Owns every `Engram.Cache` table; applies cluster and Postgres evictions; sweeps expired rows."
  use GenServer

  alias Engram.Cache
  alias Engram.Cache.Registry

  require Logger

  @sweep_ms 60_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    # Tables back user data (vault names, users rows): keep them out of crash dumps.
    _ = Process.flag(:sensitive, true)

    for %{name: name} <- Registry.caches() do
      :ets.new(Registry.table(name), [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])
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
        Logger.warning(
          "cache: PG notifications not running; TTL-only eviction for #{channel}",
          Engram.Logger.Metadata.with_category(:warning, :data, [])
        )

      _pid ->
        {:ok, _ref} = Postgrex.Notifications.listen(Engram.PgNotifications, channel)
    end
  catch
    kind, reason ->
      Logger.warning(
        "cache: failed to LISTEN #{channel} (#{kind}: #{inspect(reason)}); TTL-only eviction",
        Engram.Logger.Metadata.with_category(:warning, :data, [])
      )
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
      :ets.select_delete(Registry.table(name), [
        {{:_, :_, :"$1"}, [{:is_integer, :"$1"}, {:<, :"$1", now}], [true]}
      ])
    end

    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end
end
