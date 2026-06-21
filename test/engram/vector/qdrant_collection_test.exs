defmodule Engram.Vector.QdrantCollectionTest do
  use ExUnit.Case, async: true

  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    %{bypass: bypass}
  end

  # All tenant-scoped filters target payload fields that Qdrant Cloud
  # strict-mode requires an index for. ensure_collection must create them
  # (idempotently) or every filtered op 400s on Cloud. See #626.
  @indexed_fields ~w(user_id vault_id note_id path_hmac)

  # Stub the payload-index endpoint so tests asserting other behaviour don't
  # fail on the index PUTs ensure_collection now fires.
  defp stub_indexes(bypass, col) do
    Bypass.stub(bypass, "PUT", "/collections/#{col}/index", fn conn ->
      Plug.Conn.send_resp(conn, 200, ~s({"status":"ok"}))
    end)
  end

  test "creates a collection with named dense + keyword sparse(idf)", %{bypass: bypass} do
    stub_indexes(bypass, "c1")

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

  test "creates a keyword payload index for every filtered field after create",
       %{bypass: bypass} do
    test_pid = self()

    Bypass.expect_once(bypass, "PUT", "/collections/c1", fn conn ->
      Plug.Conn.send_resp(conn, 200, "{}")
    end)

    Bypass.expect(bypass, "PUT", "/collections/c1/index", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Jason.decode!(body)
      send(test_pid, {:index, json["field_name"], json["field_schema"]})
      Plug.Conn.send_resp(conn, 200, ~s({"status":"ok"}))
    end)

    assert :ok = Qdrant.ensure_collection("c1", 1024)

    for field <- @indexed_fields do
      assert_receive {:index, ^field, "keyword"}
    end
  end

  test "does NOT re-create payload indexes on a pre-existing collection (409)",
       %{bypass: bypass} do
    test_pid = self()

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

    # If the steady-state path wrongly (re-)created indexes, this fires.
    Bypass.stub(bypass, "PUT", "/collections/c1/index", fn conn ->
      send(test_pid, :index_called)
      Plug.Conn.send_resp(conn, 200, ~s({"status":"ok"}))
    end)

    assert :ok = Qdrant.ensure_collection("c1", 1024)
    refute_receive :index_called
  end

  # H2 — 409 "already exists" must verify the collection shape, not blindly
  # accept it. A legacy single-unnamed-vector collection would 400 every
  # named-vector upsert/search silently without this guard.

  test "409 + named-shape GET → :ok (collection shape is compatible)", %{bypass: bypass} do
    stub_indexes(bypass, "c1")

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
