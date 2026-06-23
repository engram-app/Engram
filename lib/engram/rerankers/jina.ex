defmodule Engram.Rerankers.Jina do
  @moduledoc """
  Jina AI reranker — takes Qdrant candidates, reranks by cross-encoder,
  blends scores (40% vector + 60% reranker), returns top N.

  Falls back to vector-only scoring if Jina is unavailable.
  """

  @behaviour Engram.Reranker

  alias Engram.Logger.Metadata

  require Logger

  @vector_weight 0.4
  @reranker_weight 0.6

  @impl true
  def rerank(_query, [], _top_n), do: {:ok, []}

  def rerank(query, candidates, top_n) do
    url = jina_url() || raise "JINA_URL must be configured when using Jina reranker"
    do_rerank(url, query, candidates, top_n)
  end

  defp do_rerank(url, query, candidates, top_n) do
    texts = Enum.map(candidates, & &1.text)

    body = %{
      query: query,
      documents: texts,
      top_n: length(texts)
    }

    case Req.post("#{url}/rerank",
           json: body,
           receive_timeout: 15_000,
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"results" => jina_results}}} ->
        blended = blend_scores(candidates, jina_results)
        {:ok, blended |> Enum.sort_by(& &1.score, :desc) |> Enum.take(top_n)}

      {:ok, %{status: status}} ->
        Logger.warning(
          "Jina reranker non-200, falling back to vector scores",
          Metadata.with_category(:warning, :search, status: status)
        )

        {:ok, candidates |> Enum.sort_by(& &1.score, :desc) |> Enum.take(top_n)}

      {:error, reason} ->
        Logger.warning(
          "Jina reranker failed, falling back to vector scores",
          Metadata.with_category(:warning, :search, reason: inspect(reason))
        )

        {:ok, candidates |> Enum.sort_by(& &1.score, :desc) |> Enum.take(top_n)}
    end
  rescue
    e ->
      Logger.warning(
        "Jina reranker exception, falling back to vector scores",
        Metadata.with_category(:warning, :search,
          exception: inspect(e.__struct__),
          message: Exception.message(e)
        )
      )

      {:ok, candidates |> Enum.sort_by(& &1.score, :desc) |> Enum.take(top_n)}
  end

  defp blend_scores(candidates, jina_results) do
    # Build index → reranker_score map
    reranker_scores =
      Map.new(jina_results, fn r -> {r["index"], r["relevance_score"]} end)

    # Normalize reranker scores to [0, 1]
    raw_scores = Map.values(reranker_scores)
    {min_s, max_s} = {Enum.min(raw_scores, fn -> 0 end), Enum.max(raw_scores, fn -> 0 end)}
    range = max_s - min_s

    candidates
    |> Enum.with_index()
    |> Enum.map(fn {candidate, idx} ->
      raw_reranker = Map.get(reranker_scores, idx, 0)

      normalized =
        if range == 0, do: 0.5, else: (raw_reranker - min_s) / range

      blended = @vector_weight * candidate.score + @reranker_weight * normalized
      Map.put(candidate, :score, blended)
    end)
  end

  defp jina_url, do: Application.get_env(:engram, :jina_url)
end
