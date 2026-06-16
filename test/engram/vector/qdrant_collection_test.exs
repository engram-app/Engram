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

  # H2 — 409 "already exists" must verify the collection shape, not blindly
  # accept it. A legacy single-unnamed-vector collection would 400 every
  # named-vector upsert/search silently without this guard.

  test "409 + named-shape GET → :ok (collection shape is compatible)", %{bypass: bypass} do
    Bypass.expect_once(bypass, "PUT", "/collections/c1", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(409, ~s({"status":{"error":"already exists"}}))
    end)

    named_shape_body =
      Jason.encode!(%{
        result: %{
          config: %{
            params: %{
              vectors: %{"dense" => %{size: 1024, distance: "Cosine"}},
              sparse_vectors: %{"keyword" => %{modifier: "idf"}}
            }
          }
        }
      })

    Bypass.expect_once(bypass, "GET", "/collections/c1", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, named_shape_body)
    end)

    assert :ok = Qdrant.ensure_collection("c1", 1024)
  end

  test "409 + legacy-shape GET → {:error, :incompatible_collection_schema}", %{bypass: bypass} do
    Bypass.expect_once(bypass, "PUT", "/collections/c1", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(409, ~s({"status":{"error":"already exists"}}))
    end)

    # Legacy: single unnamed-vector shape — top-level "size"/"distance" keys
    # inside "vectors", no "dense" sub-key, no "sparse_vectors".
    legacy_shape_body =
      Jason.encode!(%{
        result: %{
          config: %{
            params: %{
              vectors: %{"size" => 1024, "distance" => "Cosine"}
            }
          }
        }
      })

    Bypass.expect_once(bypass, "GET", "/collections/c1", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, legacy_shape_body)
    end)

    assert {:error, {:incompatible_collection_schema, "c1"}} =
             Qdrant.ensure_collection("c1", 1024)
  end
end
