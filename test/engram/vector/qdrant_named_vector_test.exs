defmodule Engram.Vector.QdrantNamedVectorTest do
  use ExUnit.Case, async: true

  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    %{bypass: bypass}
  end

  test "upsert sends named dense + keyword vectors verbatim", %{bypass: bypass} do
    Bypass.expect_once(bypass, "PUT", "/collections/c1/points", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      [pt] = Jason.decode!(body)["points"]
      assert pt["vector"]["dense"] == [0.1, 0.2]
      assert pt["vector"]["keyword"]["indices"] == [7]
      assert pt["vector"]["keyword"]["values"] == [1.5]
      Plug.Conn.send_resp(conn, 200, "{}")
    end)

    point = %{
      id: "p1",
      vector: %{"dense" => [0.1, 0.2], "keyword" => %{indices: [7], values: [1.5]}},
      payload: %{"user_id" => "u1"}
    }

    assert :ok = Qdrant.upsert_points("c1", [point])
  end

  test "search targets the dense named vector", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/collections/c1/points/query", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body)["using"] == "dense"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result":[]}))
    end)

    assert {:ok, []} = Qdrant.search("c1", [0.1, 0.2], user_id: "u1", limit: 5)
  end
end
