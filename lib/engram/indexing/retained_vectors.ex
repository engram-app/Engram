defmodule Engram.Indexing.RetainedVectors do
  @moduledoc """
  Dense vectors Voyage was paid for, held across the commit so a retry after
  any post-embed failure reuses them instead of paying again. Backed by the
  node-local `:retained_vectors` cache, keyed `{note_id, embed_key}`.

  Bounded per node: at most one entry per note (a new put replaces it) and
  `max_bytes` in total, evicting oldest first. A sustained Qdrant outage during
  a bulk import would otherwise pin every failed job's vectors (~30 MB for a
  7k-chunk note) for the whole TTL; the worker OOMed on 2026-10-03.
  """

  alias Engram.Cache
  alias Engram.Cache.Registry

  @cache :retained_vectors
  @default_max_bytes 256 * 1024 * 1024

  @spec get({Ecto.UUID.t(), binary()}) :: {:ok, [binary()]} | :miss
  def get(key) do
    case Cache.get(@cache, key) do
      {:ok, {_seq, _bytes, vectors}} -> {:ok, vectors}
      :miss -> :miss
    end
  end

  # ponytail: the trim is scan-then-delete, not atomic. Two jobs retaining at
  # once on one node can overshoot the cap by one entry each until the next
  # put. Rows are one per failed note, so the scan is cheap.
  @spec put({Ecto.UUID.t(), binary()}, [binary()], non_neg_integer()) :: :ok
  def put({note_id, _} = key, vectors, max_bytes \\ max_bytes()) do
    :ok = Cache.evict_local(@cache, note_id)
    bytes = vectors |> Enum.map(&byte_size/1) |> Enum.sum()

    # Larger than the whole budget: holding it would evict everything else
    # and still not fit. That note's retry re-pays.
    if bytes <= max_bytes do
      :ok = trim(max_bytes - bytes)
      Cache.put(@cache, key, {System.unique_integer([:monotonic]), bytes, vectors})
    else
      :ok
    end
  end

  @spec forget({Ecto.UUID.t(), binary()}) :: :ok
  def forget({note_id, _}), do: Cache.evict_local(@cache, note_id)

  @doc "Bytes of vectors currently held on this node."
  @spec total_bytes() :: non_neg_integer()
  def total_bytes, do: entries() |> Enum.map(&elem(&1, 2)) |> Enum.sum()

  defp max_bytes,
    do: Engram.ServiceConfig.get(:retained_vectors_max_bytes, @default_max_bytes)

  # Oldest first until what remains fits in `budget`.
  defp trim(budget) do
    held = entries()
    total = held |> Enum.map(&elem(&1, 2)) |> Enum.sum()

    _remaining =
      held
      |> Enum.sort_by(&elem(&1, 1))
      |> Enum.reduce_while(total, fn {{note_id, _}, _seq, bytes}, total ->
        if total > budget do
          :ok = Cache.evict_local(@cache, note_id)
          {:cont, total - bytes}
        else
          {:halt, total}
        end
      end)

    :ok
  end

  @spec entries() :: [{{Ecto.UUID.t(), binary()}, integer(), non_neg_integer()}]
  defp entries do
    :ets.select(Registry.table(@cache), [
      {{:"$1", {:"$2", :"$3", :_}, :_}, [{:is_integer, :"$2"}, {:is_integer, :"$3"}],
       [{{:"$1", :"$2", :"$3"}}]}
    ])
  rescue
    ArgumentError -> []
  end
end
