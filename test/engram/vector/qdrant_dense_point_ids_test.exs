defmodule Engram.Vector.QdrantDensePointIdsTest do
  @moduledoc """
  Embed less: a note's frontmatter and data points carry only the `keyword`
  vector, so `similar_to` passes only the ids `has_vector: "dense"` keeps.
  Bypass answers 200 to anything, so only a real Qdrant proves the filter.
  """
  use ExUnit.Case, async: false

  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant

  @moduletag :qdrant_integration

  @dims 8
  @user_id "11111111-1111-1111-1111-111111111111"
  @vault_id "22222222-2222-2222-2222-222222222222"

  setup do
    ServiceConfig.put_override(:qdrant_url, qdrant_url())

    col =
      "engram_dense_ids_#{System.get_env("MIX_TEST_PARTITION")}_#{System.unique_integer([:positive])}"

    :ok = Qdrant.ensure_collection(col, @dims)
    Engram.QdrantIntegration.drop_on_exit(col)

    dense = Ecto.UUID.generate()
    sparse = Ecto.UUID.generate()
    neighbour = Ecto.UUID.generate()

    :ok =
      Qdrant.upsert_points(col, [
        point(dense, %{"dense" => List.duplicate(0.1, @dims), "keyword" => keyword()}),
        point(sparse, %{"keyword" => keyword()}),
        point(neighbour, %{"dense" => List.duplicate(0.2, @dims)})
      ])

    %{col: col, dense: dense, sparse: sparse, neighbour: neighbour}
  end

  test "keeps only the points that hold a dense vector", %{col: col, dense: d, sparse: s} do
    assert Qdrant.dense_point_ids(col, [d, s]) == {:ok, [d]}
    assert Qdrant.dense_point_ids(col, [s]) == {:ok, []}
    assert Qdrant.dense_point_ids(col, []) == {:ok, []}
  end

  # Our contract: the dense ids `dense_point_ids/2` returns are a valid
  # recommend on their own. What a server does with a sparse-only positive
  # differs by version (1.19.2 refuses it with a 4xx; 1.17.1, CI's pin, has
  # answered both 200 with no hits and 200 with the neighbour), so nothing
  # here depends on it. `similar_to` never sends one (handlers_similar_test).
  test "the dense ids alone recommend the note's neighbour", ctx do
    opts = [user_id: @user_id, vault_id: @vault_id, limit: 1]
    {:ok, ids} = Qdrant.dense_point_ids(ctx.col, [ctx.dense, ctx.sparse])

    assert {:ok, [%{qdrant_id: id}]} = Qdrant.recommend(ctx.col, ids, opts)
    assert id == ctx.neighbour
  end

  defp point(id, vector),
    do: %{id: id, vector: vector, payload: %{user_id: @user_id, vault_id: @vault_id}}

  defp keyword, do: %{indices: [1, 2], values: [1.0, 0.5]}

  defp qdrant_url do
    System.get_env("QDRANT_URL") ||
      Application.get_env(:engram, :qdrant_url, "http://localhost:6333")
  end
end
