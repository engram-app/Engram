defmodule Engram.Search.Fusion do
  @moduledoc """
  Reciprocal rank fusion of ranked search legs, done here rather than by
  Qdrant's server-side `fusion: "rrf"`.

  Qdrant breaks fused-score ties in no fixed order, so the same query over
  the same index could return a different page (ties are common: a point at
  rank r in one leg ties every other point at rank r in one leg). Here a tie
  breaks by the point's best leg score, then by id, so the order is a pure
  function of the legs.
  """

  @type hit :: %{
          required(:id) => term(),
          required(:score) => number(),
          optional(atom()) => term()
        }

  @doc """
  Fuses `legs` (each ranked best first) by `1 / (k + rank)`, rank zero-based,
  summed over the legs a point appears in. Sorted by fused score desc, then
  max leg score desc, then id asc. A point keeps the map of the first leg it
  appears in, with `:score` replaced by the fused score.
  """
  @spec rrf([[hit()]], pos_integer()) :: [hit()]
  def rrf(legs, k) when is_list(legs) and is_integer(k) and k > 0 do
    legs
    |> Enum.flat_map(&Enum.with_index/1)
    |> Enum.reduce(%{}, fn {hit, rank}, acc ->
      rrf = 1 / (k + rank)

      Map.update(acc, hit.id, {hit, rrf, hit.score}, fn {first, fused, best} ->
        {first, fused + rrf, max(best, hit.score)}
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(fn {hit, fused, best} -> {-fused, -best, hit.id} end)
    |> Enum.map(fn {hit, fused, _best} -> %{hit | score: fused} end)
  end
end
