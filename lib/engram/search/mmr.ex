defmodule Engram.Search.MMR do
  @moduledoc """
  Maximal Marginal Relevance reselection.

  Greedily picks `limit` candidates from a relevance-sorted pool, each step
  maximising `(1 - d) * rel - d * max_sim_to_already_picked`, where `rel` is the
  candidate's relevance score normalised to [0,1] within the pool and `sim` is
  cosine similarity between dense vectors. `d` (diversity) ∈ [0,1].

  `d == 0.0` short-circuits to the relevance order (no vectors required).

  The selection runs in Rust (`Engram.Native.mmr_select/5`, #1798): O(pool ×
  limit) dot products over unit vectors, each candidate carrying its running
  max similarity to the picked set (#1617). In Elixir every multiply-add
  allocated a boxed float, ~2.5 s for a limit-50 rerank over a 200 × 1024
  pool. Ties resolve in pool order.

  A nil or zero vector (a sparse-only chunk: frontmatter, data, canvas) is
  similarity 1.0 to every chunk of its own note (`{vault_id, source_path}`)
  and otherwise takes the direction of that note's best dense chunk in the
  pool. Scored 0.0, it dodged every penalty and outranked the note's prose.
  With no dense sibling it has no direction: 0.0.
  """

  @spec rerank([map()], pos_integer(), float()) :: [map()]
  def rerank(candidates, limit, diversity)

  def rerank(candidates, limit, diversity) when diversity == 0.0,
    do: Enum.take(candidates, limit)

  def rerank(_candidates, limit, _diversity) when limit <= 0, do: []

  def rerank(candidates, limit, diversity)
      when is_list(candidates) and is_number(diversity) do
    pool = List.to_tuple(candidates)

    candidates
    |> Enum.map(&Map.get(&1, :vector))
    |> Engram.Native.mmr_select(
      Enum.map(candidates, & &1.score),
      note_groups(candidates),
      limit,
      diversity
    )
    |> Enum.map(&elem(pool, &1))
  end

  # One integer per note. A candidate without a source_path is its own group.
  defp note_groups(candidates) do
    keys =
      candidates
      |> Enum.with_index()
      |> Enum.map(fn
        {%{source_path: path} = c, _i} when is_binary(path) -> {Map.get(c, :vault_id), path}
        {_c, i} -> {:solo, i}
      end)

    ids = keys |> Enum.uniq() |> Enum.with_index() |> Map.new()
    Enum.map(keys, &Map.fetch!(ids, &1))
  end
end
