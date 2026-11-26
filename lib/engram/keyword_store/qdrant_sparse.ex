defmodule Engram.KeywordStore.QdrantSparse do
  @moduledoc """
  Keyword store backend #1: the sparse `keyword` named vector on the chunk's
  dense Qdrant point, exactly as before the seam (see `Engram.KeywordStore`).
  Self-host keeps it for good (roadmap D11).

  Colocated: deletes are no-ops because every call site's dense delete
  removes the point, keyword vector included. Issuing them again would
  double each site's Qdrant delete requests for nothing.
  """
  @behaviour Engram.KeywordStore

  alias Engram.Indexing
  alias Engram.Vector.Qdrant

  @vector "keyword"

  @impl true
  def point_vectors(sparse), do: %{@vector => sparse}

  # Sparse-only update of points that exist (`PUT /points/vectors`): the
  # dense vector and payload stay as they are.
  @impl true
  def upsert(_scope, entries) do
    points =
      Enum.map(entries, &Indexing.unpack_point(%{id: &1.id, vector: point_vectors(&1.sparse)}))

    Qdrant.update_vectors(Qdrant.collection_name(), points)
  end

  # ponytail: no-ops while colocated (the dense delete beside each call
  # covers them); a non-colocated backend implements real deletes.
  @impl true
  def delete_points(_user_id, _ids), do: :ok

  @impl true
  def delete_note(_user_id, _vault_id, _note_id, _keep), do: :ok

  @impl true
  def delete_vault(_user_id, _vault_id), do: :ok

  @impl true
  def delete_user(_user_id), do: :ok

  @impl true
  def search(sparse, search_opts),
    do: Qdrant.sparse_search(Qdrant.collection_name(), sparse, search_opts)

  # One `/points/query/batch` request for both legs, fused client-side.
  @impl true
  def hybrid_search(dense, sparse, search_opts),
    do: Qdrant.hybrid_search(Qdrant.collection_name(), dense, sparse, search_opts)
end
