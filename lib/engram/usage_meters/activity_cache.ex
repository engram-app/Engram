defmodule Engram.UsageMeters.ActivityCache do
  @moduledoc """
  Per-node ETS cache of the last time we stamped `usage_meters.last_active_at`
  for a user. Lets `EngramWeb.Plugs.BumpActivity` skip the per-request meter
  read once it knows (from this node) that the user was bumped within the
  debounce window.

  The table is `:public` — the cached value is a non-secret timestamp, so
  request processes read and write it directly with no GenServer hop. This
  process exists only to own the table for the application's lifetime. Entries
  are tiny (`{user_id, %DateTime{}}`) and bounded by the active-user count, so
  no sweep is needed; staleness is decided by the caller comparing timestamps.

  On node restart the table is empty, so each user triggers one cold-path
  meter read again — harmless and self-healing.
  """

  use GenServer

  @table :engram_activity_cache

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @spec get(user_id :: integer()) :: {:ok, DateTime.t()} | :miss
  def get(user_id) do
    case :ets.lookup(@table, user_id) do
      [{^user_id, %DateTime{} = ts}] -> {:ok, ts}
      [] -> :miss
    end
  end

  @spec put(user_id :: integer(), last_active_at :: DateTime.t()) :: :ok
  def put(user_id, %DateTime{} = last_active_at) do
    :ets.insert(@table, {user_id, last_active_at})
    :ok
  end

  @impl true
  def init(:ok) do
    _ =
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, %{}}
  end
end
