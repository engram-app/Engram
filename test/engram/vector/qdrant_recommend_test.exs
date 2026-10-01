defmodule Engram.Vector.QdrantRecommendTest do
  use ExUnit.Case, async: true

  alias Engram.Vector.Qdrant

  test "averages the positive points, excludes them, keeps the tenant filter" do
    body = Qdrant.recommend_body(["p1", "p2"], user_id: "u1", vault_id: "v1", limit: 7)

    assert body.query == %{recommend: %{positive: ["p1", "p2"], strategy: "average_vector"}}
    assert body.using == "dense"
    assert body.limit == 7
    assert body.with_payload == true
    assert body.filter.must_not == [%{has_id: ["p1", "p2"]}]
    assert %{key: "user_id", match: %{value: "u1"}} in body.filter.must
    assert %{key: "vault_id", match: %{value: "v1"}} in body.filter.must
  end
end
