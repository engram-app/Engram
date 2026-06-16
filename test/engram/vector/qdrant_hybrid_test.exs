defmodule Engram.Vector.QdrantHybridTest do
  use ExUnit.Case, async: true

  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    %{bypass: bypass}
  end

  test "hybrid issues two prefetches with tenant filter + rrf fusion", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/collections/c1/points/query", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Jason.decode!(body)
      [dense_pf, kw_pf] = json["prefetch"]
      assert dense_pf["using"] == "dense"
      assert kw_pf["using"] == "keyword"
      assert kw_pf["query"]["indices"] == [7]
      assert json["query"]["fusion"] == "rrf"
      assert dense_pf["filter"]["must"] |> Enum.any?(&(&1["key"] == "user_id"))
      assert kw_pf["filter"]["must"] |> Enum.any?(&(&1["key"] == "user_id"))

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result":{"points":[]}}))
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

  test "hybrid_search parses non-empty result correctly", %{bypass: bypass} do
    response_body =
      Jason.encode!(%{
        result: %{
          points: [
            %{id: "p1", score: 0.016, payload: %{text: "hello world", title: "My Note"}}
          ]
        }
      })

    Bypass.expect_once(bypass, "POST", "/collections/c1/points/query", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, response_body)
    end)

    sparse = %{indices: [7], values: [1.0]}

    assert {:ok, [result]} =
             Qdrant.hybrid_search("c1", [0.1], sparse, user_id: "u1", vault_id: "v1", limit: 5)

    assert result[:score] == 0.016
    assert result[:text] == "hello world"
    assert result[:title] == "My Note"
    assert result[:qdrant_id] == "p1"
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
