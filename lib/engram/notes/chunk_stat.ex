defmodule Engram.Notes.ChunkStat do
  @moduledoc """
  A vault's chunk counters (migration 20261025000200): its points (chunk
  rows), and the rows with a `token_count` and their sum, for BM25 `avgdl`.
  Written only by the `chunks_stats_*` triggers; read by
  `Indexing.points_by_user/0` and `KeywordIndex.Stats`.
  """
  use Ecto.Schema

  @primary_key {:vault_id, :binary_id, autogenerate: false}
  schema "chunk_stats" do
    field :user_id, :binary_id
    field :points, :integer
    field :len_rows, :integer
    field :len_sum, :integer
  end
end
