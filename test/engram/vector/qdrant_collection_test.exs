defmodule Engram.Vector.QdrantCollectionTest do
  use ExUnit.Case, async: false

  alias Engram.Vector.Qdrant

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)
    %{bypass: bypass}
  end

  test "creates a collection with named dense + keyword sparse(idf)", %{bypass: bypass} do
    Bypass.expect_once(bypass, "PUT", "/collections/c1", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Jason.decode!(body)
      assert json["vectors"]["dense"]["size"] == 1024
      assert json["vectors"]["dense"]["distance"] == "Cosine"
      assert json["sparse_vectors"]["keyword"]["modifier"] == "idf"
      Plug.Conn.send_resp(conn, 200, "{}")
    end)

    assert :ok = Qdrant.ensure_collection("c1", 1024)
  end
end
