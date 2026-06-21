defmodule Engram.Usage.DailyCap.Cache do
  @moduledoc """
  Per-node ETS cache of *known-empty* buckets only. Stores `{key, expires_at}`
  in monotonic ms; once a bucket runs dry we cache that verdict until roughly
  one token regenerates, so a capped user is rejected without touching Postgres.
  We never cache the *allowed* verdict — that path is authoritative in PG.
  Per-node staleness is safe: at worst a node lets one extra request reach PG
  after the real refill, which PG then adjudicates exactly.
  """
  use GenServer
  @table :engram_daily_cap_empty

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @spec mark_empty(integer(), String.t(), non_neg_integer()) :: :ok
  def mark_empty(user_id, kind, retry_after_sec) do
    expires = System.monotonic_time(:millisecond) + retry_after_sec * 1000
    :ets.insert(@table, {{user_id, kind}, expires})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec empty_until(integer(), String.t()) :: {:empty, non_neg_integer()} | :unknown
  def empty_until(user_id, kind) do
    case :ets.lookup(@table, {user_id, kind}) do
      [{_, expires}] ->
        remaining = expires - System.monotonic_time(:millisecond)
        if remaining > 0, do: {:empty, ceil(remaining / 1000)}, else: :unknown

      _ ->
        :unknown
    end
  rescue
    ArgumentError -> :unknown
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    {:ok, %{}}
  end
end
