defmodule Engram.Usage.DailyCap.Cache do
  @moduledoc """
  Per-node ETS cache of *known-empty* buckets only. Stores `{key, expires_at}`
  in monotonic ms; once a bucket runs dry we cache that verdict until roughly
  one token regenerates, so a capped user is rejected without touching Postgres.
  We never cache the *allowed* verdict — that path is authoritative in PG.
  Per-node staleness is safe: at worst a node lets one extra request reach PG
  after the real refill, which PG then adjudicates exactly.
  """
  use Engram.Cache.NodeLocalEts, table: :engram_daily_cap_empty

  @spec mark_empty(binary(), String.t(), non_neg_integer()) :: :ok
  def mark_empty(user_id, kind, retry_after_sec) do
    expires = System.monotonic_time(:millisecond) + retry_after_sec * 1000
    ets_insert({{user_id, kind}, expires})
  end

  @spec empty_until(binary(), String.t()) :: {:empty, non_neg_integer()} | :unknown
  def empty_until(user_id, kind) do
    case ets_lookup({user_id, kind}) do
      [{_, expires}] ->
        remaining = expires - System.monotonic_time(:millisecond)
        if remaining > 0, do: {:empty, ceil(remaining / 1000)}, else: :unknown

      _ ->
        :unknown
    end
  end
end
