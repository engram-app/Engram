defmodule Engram.Vector.QdrantNamedVectorTest do
  use ExUnit.Case, async: true

  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")

    # The search path's prod budget is 5s (`:qdrant_search_timeout`), which is
    # tuned for a real network and is not what these tests are about — they
    # assert the request SHAPE (named vectors in, `using: "dense"` out). On a
    # box running the suite under load a localhost Bypass round trip can pass
    # 5s through pure scheduler starvation, which then fails as a
    # `%Req.TransportError{reason: :timeout}` and reads like a routing bug.
    ServiceConfig.put_override(:qdrant_search_timeout, 30_000)

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
