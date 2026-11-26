defmodule Engram.KeywordStore.Shadow do
  @moduledoc """
  Shadow compare (search storage roadmap P2 task 8): on a sample of live
  searches, the kwsearch keyword leg runs beside the sparse store's and the
  two top 10s are compared. Metrics only: the result is never served, and
  the search does not wait for it (a supervised task after the reply path).

  Runs only while reads stay on the sparse store (`KeywordStore.read/0`),
  the feed is written, and `:keyword_shadow_rate` (`KEYWORD_SHADOW_RATE`,
  0 to 1, default 0: off) picks the search. Each sample costs one extra
  keyword-only query on each store.

  Emits `[:engram, :search, :keyword_shadow]` with `overlap` (share of the
  sparse top 10 that kwsearch also returned, 1.0 when both are empty; also
  as a whole percent, `overlap_pct`, for `Engram.PromEx.Search`),
  `tantivy_ms` and `sparse_ms`, tagged `outcome`: `ok`, or `error` when
  either leg failed (kwsearch down or rebuilding counts here, not in the
  live fallback counter).
  """

  alias Engram.KeywordStore
  alias Engram.KeywordStore.Tantivy
  alias Engram.ServiceConfig

  @top 10

  @doc "Starts a compare for this search when sampled; never blocks or fails it."
  @spec maybe_compare(map(), keyword()) :: :ok
  def maybe_compare(sparse, search_opts) do
    rate = ServiceConfig.get(:keyword_shadow_rate, 0.0)

    if rate > 0 and KeywordStore.read() == :sparse and KeywordStore.feed?() and
         :rand.uniform() <= rate,
       do: start(sparse, search_opts),
       else: :ok
  end

  defp start(sparse, search_opts) do
    {:ok, _pid} =
      Task.Supervisor.start_child(Engram.TaskSupervisor, fn -> compare(sparse, search_opts) end)

    :ok
  end

  @doc "Runs both keyword legs for one search and emits the compare."
  @spec compare(map(), keyword()) :: :ok
  def compare(sparse, search_opts) do
    opts = Keyword.put(search_opts, :limit, @top)
    {t_us, tantivy} = :timer.tc(fn -> Tantivy.keyword_hits(sparse, opts) end)
    {s_us, qdrant} = :timer.tc(fn -> KeywordStore.impl().search(sparse, opts) end)

    {outcome, overlap} =
      case {tantivy, qdrant} do
        {{:ok, t}, {:ok, q}} -> {:ok, overlap(ids(t), ids(q))}
        _ -> {:error, 0.0}
      end

    :telemetry.execute(
      [:engram, :search, :keyword_shadow],
      %{
        overlap: overlap,
        overlap_pct: round(overlap * 100),
        tantivy_ms: t_us / 1000,
        sparse_ms: s_us / 1000
      },
      %{outcome: outcome}
    )
  end

  @doc false
  def overlap(tantivy, sparse) do
    case MapSet.size(sparse) do
      0 -> if MapSet.size(tantivy) == 0, do: 1.0, else: 0.0
      n -> MapSet.size(MapSet.intersection(tantivy, sparse)) / n
    end
  end

  defp ids(hits), do: hits |> Enum.take(@top) |> MapSet.new(&to_string(&1.qdrant_id))
end
