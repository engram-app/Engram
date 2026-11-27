defmodule Engram.KeywordStore.Shadow do
  @moduledoc """
  Shadow compare (search storage roadmap P2 task 8): on a sample of live
  searches, the kwsearch keyword leg runs beside the sparse store's and the
  two top 10s are compared. Metrics only: the result is never served, and
  the search does not wait for it (a supervised task after the reply path).

  Runs only while reads stay on the sparse store (`KeywordStore.read/0`),
  the feed is written, and `:keyword_shadow_permille` (`KEYWORD_SHADOW_RATE`
  at boot, a runtime override after; default 0: off) picks the search. Each
  sample costs one extra keyword-only query on each store: at most
  ONE runs at a time (else the sample is dropped), and the sparse one takes
  a slot of the live searches' gate only when one is free right now with
  another to spare, under its own key (`Engram.Search.Gate.try_run/1`): it
  never waits, never queues, never uses a user's per-user slots, and is
  dropped (outcome `busy`) instead (reviews M2, N1).

  Emits `[:engram, :search, :keyword_shadow]` with `overlap` (share of the
  sparse top 10 that kwsearch also returned, 1.0 when both are empty; also
  as a whole percent, `overlap_pct`, for `Engram.PromEx.Search`),
  `tantivy_ms` and `sparse_ms`, tagged `outcome`: `ok`, `busy` (the sparse
  leg was refused by the gate), or `error` when either leg failed (kwsearch down or rebuilding counts here, not in the
  live fallback counter).
  """

  alias Engram.KeywordStore
  alias Engram.KeywordStore.Tantivy
  alias Engram.Search.Gate
  alias Engram.ServiceConfig

  @top 10
  @max_in_flight 1
  @slots {__MODULE__, :in_flight}

  @doc "Starts a compare for this search when sampled; never blocks or fails it."
  @spec maybe_compare(map(), keyword()) :: :ok
  def maybe_compare(sparse, search_opts) do
    permille = ServiceConfig.get(:keyword_shadow_permille, 0)

    if permille > 0 and KeywordStore.read() == :sparse and KeywordStore.feed?() and
         :rand.uniform(1000) <= permille,
       do: start(sparse, search_opts),
       else: :ok
  end

  # A slot, then a supervised task that gives it back. No slot, or no task
  # (the supervisor shutting down): the sample is dropped, never a raise
  # inside the live search.
  defp start(sparse, search_opts) do
    slots = slots()

    if :atomics.add_get(slots, 1, 1) <= @max_in_flight do
      case Task.Supervisor.start_child(Engram.TaskSupervisor, fn ->
             try do
               compare(sparse, search_opts)
             after
               :atomics.sub(slots, 1, 1)
             end
           end) do
        {:ok, _pid} -> :ok
        _ -> release(slots)
      end
    else
      release(slots)
    end
  catch
    _kind, _reason -> :ok
  end

  defp release(slots) do
    :atomics.sub(slots, 1, 1)
    :ok
  end

  @doc false
  def slots do
    case :persistent_term.get(@slots, nil) do
      nil ->
        ref = :atomics.new(1, [])
        :persistent_term.put(@slots, ref)
        ref

      ref ->
        ref
    end
  end

  @doc "Runs both keyword legs for one search and emits the compare."
  @spec compare(map(), keyword()) :: :ok
  def compare(sparse, search_opts) do
    opts = Keyword.put(search_opts, :limit, @top)
    {t_us, tantivy} = :timer.tc(fn -> Tantivy.keyword_hits(sparse, opts) end)

    {s_us, sparse_hits} =
      :timer.tc(fn ->
        Gate.try_run(fn ->
          Gate.pool_busy(:qdrant, fn -> KeywordStore.impl().search(sparse, opts) end)
        end)
      end)

    {outcome, overlap} =
      case {tantivy, sparse_hits} do
        {{:ok, t}, {:ok, q}} -> {:ok, overlap(ids(t), ids(q))}
        {_, {:error, :search_busy}} -> {:busy, 0.0}
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
