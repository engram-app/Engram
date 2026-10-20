defmodule Engram.Vector.QdrantHybridTest do
  use ExUnit.Case, async: true

  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    # The search path fails fast at 5s (`:qdrant_search_timeout`), a prod
    # budget. Under full-suite load a Bypass reply can starve past it, which
    # reads as `%Req.TransportError{reason: :timeout}`, not a real failure.
    ServiceConfig.put_override(:qdrant_search_timeout, 30_000)
    %{bypass: bypass}
  end

  test "hybrid sends one batch: a dense and a keyword request, both tenant-filtered",
       %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/collections/c1/points/query/batch", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Jason.decode!(body)
      [dense, kw] = json["searches"]
      assert dense["using"] == "dense"
      assert kw["using"] == "keyword"
      assert kw["query"]["indices"] == [7]
      assert dense["limit"] == 5 and kw["limit"] == 5
      refute Map.has_key?(json, "prefetch")
      assert dense["filter"]["must"] |> Enum.any?(&(&1["key"] == "user_id"))
      assert kw["filter"]["must"] |> Enum.any?(&(&1["key"] == "user_id"))

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result":[{"points":[]},{"points":[]}]}))
    end)

    sparse = %{indices: [7], values: [1.0]}

    assert {:ok, []} =
             Qdrant.hybrid_search("c1", [0.1], sparse, user_id: "u1", vault_id: "v1", limit: 5)
  end

  test "keyword-only search targets the sparse vector", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/collections/c1/points/query", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Jason.decode!(body)
      assert json["using"] == "keyword"
      assert json["query"]["indices"] == [7]

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result":[]}))
    end)

    assert {:ok, []} =
             Qdrant.sparse_search("c1", %{indices: [7], values: [1.0]}, user_id: "u1", limit: 5)
  end

  defp point(id, score), do: %{id: id, score: score, payload: %{text: "t-#{id}"}}

  test "hybrid fuses the legs client-side by RRF and keeps payload fields", %{bypass: bypass} do
    response_body =
      Jason.encode!(%{
        result: [
          %{points: [point("p1", 0.9), point("p2", 0.8)]},
          %{points: [point("p3", 5.0), point("p2", 4.0)]}
        ]
      })

    Bypass.expect_once(bypass, "POST", "/collections/c1/points/query/batch", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      # Fusion needs ids and scores only.
      searches = Jason.decode!(body)["searches"]
      assert length(searches) == 2
      assert Enum.all?(searches, &(&1["with_payload"] == false))

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, response_body)
    end)

    # One retrieve, for the fused `limit` only, with the result fields and no
    # vector (none asked). Answered out of order: the fused order must hold.
    Bypass.expect_once(bypass, "POST", "/collections/c1/points", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Jason.decode!(body)
      assert json["ids"] == ["p2", "p1"]
      assert "text" in json["with_payload"] and "aad_version" in json["with_payload"]
      refute "user_id" in json["with_payload"]
      refute Map.has_key?(json, "with_vector")

      points = Enum.map(["p1", "p2"], &%{id: &1, payload: %{text: "t-#{&1}"}})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{result: points}))
    end)

    sparse = %{indices: [7], values: [1.0]}

    assert {:ok, [first | _] = results} =
             Qdrant.hybrid_search("c1", [0.1], sparse, user_id: "u1", vault_id: "v1", limit: 2)

    # p2: rank 1 in both legs = 1/3 + 1/3. p1 and p3 tie at 1/2 (rank 0 in
    # one leg each, best rank 0 both), so the id breaks it, never p3's larger
    # raw BM25 score. Only two survive.
    assert Enum.map(results, & &1.qdrant_id) == ["p2", "p1"]
    assert_in_delta first.score, 2 / 3, 1.0e-12
    assert first.text == "t-p2"
    refute Map.has_key?(first, :id)
  end

  test "hybrid answers an error, not a crash, when the batch result is not a list",
       %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/collections/c1/points/query/batch", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result":{"points":[]}}))
    end)

    assert {:error, {200, %{"points" => []}}} =
             Qdrant.hybrid_search("c1", [0.1], %{indices: [7], values: [1.0]},
               user_id: "u1",
               limit: 5
             )
  end

  test "sparse_search filter includes both user_id and vault_id", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/collections/c1/points/query", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Jason.decode!(body)
      must = json["filter"]["must"]
      assert Enum.any?(must, &(&1["key"] == "user_id" and &1["match"]["value"] == "u1"))
      assert Enum.any?(must, &(&1["key"] == "vault_id" and &1["match"]["value"] == "v1"))

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result":[]}))
    end)

    assert {:ok, []} =
             Qdrant.sparse_search("c1", %{indices: [7], values: [1.0]},
               user_id: "u1",
               vault_id: "v1",
               limit: 5
             )
  end
end
