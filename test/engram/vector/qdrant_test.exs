defmodule Engram.Vector.QdrantTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Engram.Vector.Qdrant

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)
    %{bypass: bypass}
  end

  describe "ensure_collection/2" do
    test "creates collection with binary quantization config", %{bypass: bypass} do
      Bypass.expect_once(bypass, "PUT", "/collections/test_col", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["vectors"]["size"] == 1024
        assert decoded["vectors"]["distance"] == "Cosine"

        quant = decoded["quantization_config"]["binary"]
        assert quant["always_ram"] == true

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": true}))
      end)

      assert :ok = Qdrant.ensure_collection("test_col", 1024)
    end

    test "omits quantization config when binary quantization is disabled", %{bypass: bypass} do
      Application.put_env(:engram, :qdrant_binary_quantization, false)
      on_exit(fn -> Application.delete_env(:engram, :qdrant_binary_quantization) end)

      Bypass.expect_once(bypass, "PUT", "/collections/test_col", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["vectors"]["size"] == 1024
        assert decoded["vectors"]["distance"] == "Cosine"
        refute Map.has_key?(decoded, "quantization_config")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": true}))
      end)

      assert :ok = Qdrant.ensure_collection("test_col", 1024)
    end
  end

  describe "upsert_points/2" do
    test "puts points to collection", %{bypass: bypass} do
      points = [
        %{id: "uuid-1", vector: [0.1, 0.2], payload: %{user_id: "1", path: "a.md"}}
      ]

      Bypass.expect_once(bypass, "PUT", "/collections/test_col/points", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert length(decoded["points"]) == 1

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": {"status": "ok"}}))
      end)

      assert :ok = Qdrant.upsert_points("test_col", points)
    end
  end

  describe "set_payload/3" do
    test "patches payload onto specific point ids without re-upserting vectors", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/test_col/points/payload", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["points"] == ["uuid-1", "uuid-2"]
        assert decoded["payload"]["path_hmac"] == "AAAA"
        assert decoded["payload"]["folder_hmac"] == "BBBB"
        assert decoded["payload"]["tags_hmac"] == ["TTTT"]
        # Vectors must NOT be sent — set_payload is a payload-only PATCH.
        refute Map.has_key?(decoded, "vectors")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": {"status": "acknowledged"}}))
      end)

      payload = %{path_hmac: "AAAA", folder_hmac: "BBBB", tags_hmac: ["TTTT"]}
      assert :ok = Qdrant.set_payload("test_col", ["uuid-1", "uuid-2"], payload)
    end

    test "returns :ok on empty point list without HTTP call", %{bypass: bypass} do
      # No Bypass.expect — any call would fail the test
      Bypass.stub(bypass, "POST", "/collections/test_col/points/payload", fn _ ->
        flunk("set_payload must not call Qdrant for empty point list")
      end)

      assert :ok = Qdrant.set_payload("test_col", [], %{path_hmac: "x"})
    end

    test "returns error on non-200 response", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/test_col/points/payload", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, ~s({"status":{"error":"bad request"}}))
      end)

      assert {:error, {400, _}} = Qdrant.set_payload("test_col", ["uuid-1"], %{path_hmac: "x"})
    end
  end

  describe "delete_by_vault/3" do
    test "posts correct filter with user_id and vault_id must conditions", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/test_col/points/delete", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        conditions = decoded["filter"]["must"]
        keys = Enum.map(conditions, & &1["key"])

        assert length(conditions) == 2
        assert "user_id" in keys
        assert "vault_id" in keys

        user_cond = Enum.find(conditions, &(&1["key"] == "user_id"))
        vault_cond = Enum.find(conditions, &(&1["key"] == "vault_id"))
        assert user_cond["match"]["value"] == "user-abc"
        assert vault_cond["match"]["value"] == "vault-xyz"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": {"status": "ok"}}))
      end)

      assert :ok = Qdrant.delete_by_vault("test_col", "user-abc", "vault-xyz")
    end

    test "returns :ok on 200 response", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/test_col/points/delete", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": {"status": "ok"}}))
      end)

      assert :ok = Qdrant.delete_by_vault("test_col", "user-1", "vault-1")
    end

    test "returns error on non-200 response", %{bypass: bypass} do
      # Use 400 (not retried by Req's :transient policy — only 408/429/500/502/503/504 are)
      Bypass.expect_once(bypass, "POST", "/collections/test_col/points/delete", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, ~s({"status": {"error": "bad request"}}))
      end)

      assert {:error, {400, _}} = Qdrant.delete_by_vault("test_col", "user-1", "vault-1")
    end

    test "does not include source_path in filter (vault-wide, not note-scoped)", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/test_col/points/delete", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        keys = Enum.map(decoded["filter"]["must"], & &1["key"])

        refute "source_path" in keys

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": {"status": "ok"}}))
      end)

      assert :ok = Qdrant.delete_by_vault("test_col", "user-1", "vault-1")
    end
  end

  describe "delete_by_note/4" do
    test "posts filter delete for user+vault+path", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/test_col/points/delete", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        conditions = decoded["filter"]["must"]
        keys = Enum.map(conditions, & &1["key"])
        assert "user_id" in keys
        assert "source_path" in keys

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": {"status": "ok"}}))
      end)

      assert :ok = Qdrant.delete_by_note("test_col", "user-1", "vault-1", "Test/Note.md")
    end
  end

  describe "search/3" do
    test "returns search results", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/test_col/points/query", fn conn ->
        resp = %{
          "result" => [
            %{
              "id" => "uuid-1",
              "score" => 0.95,
              "payload" => %{
                "text" => "hello",
                "title" => "Note",
                "heading_path" => "Note > Section",
                "source_path" => "Test/Note.md",
                "tags" => [],
                "user_id" => "1"
              }
            }
          ]
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end)

      vector = List.duplicate(0.1, 1024)
      assert {:ok, results} = Qdrant.search("test_col", vector, user_id: "1", limit: 5)
      assert length(results) == 1
      assert hd(results).score == 0.95
    end

    test "translates :folder_hmac opt to folder_hmac filter key (Phase B.2.3)",
         %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/test_col/points/query", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        conditions = decoded["filter"]["must"]

        cond = Enum.find(conditions, &(&1["key"] == "folder_hmac"))
        assert cond, "expected a folder_hmac filter, got #{inspect(conditions)}"
        assert cond["match"]["value"] == "FOLDER-HMAC-B64"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"result" => []}))
      end)

      vector = List.duplicate(0.1, 1024)

      assert {:ok, []} =
               Qdrant.search("test_col", vector,
                 user_id: "1",
                 folder_hmac: "FOLDER-HMAC-B64"
               )
    end

    test "translates :tags_hmac opt to tags_hmac filter with match.any (Phase B.2.3)",
         %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/test_col/points/query", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        conditions = decoded["filter"]["must"]

        cond = Enum.find(conditions, &(&1["key"] == "tags_hmac"))
        assert cond, "expected a tags_hmac filter, got #{inspect(conditions)}"
        assert Enum.sort(cond["match"]["any"]) == Enum.sort(["HASH-A", "HASH-B"])

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"result" => []}))
      end)

      vector = List.duplicate(0.1, 1024)

      assert {:ok, []} =
               Qdrant.search("test_col", vector,
                 user_id: "1",
                 tags_hmac: ["HASH-A", "HASH-B"]
               )
    end

    test "includes binary quantization rescore params", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/test_col/points/query", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["params"]["quantization"]["rescore"] == true
        assert decoded["params"]["quantization"]["oversampling"] == 3.0

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"result" => []}))
      end)

      vector = List.duplicate(0.1, 1024)
      assert {:ok, []} = Qdrant.search("test_col", vector, user_id: "1", limit: 5)
    end

    test "omits rescore params when binary quantization is disabled", %{bypass: bypass} do
      Application.put_env(:engram, :qdrant_binary_quantization, false)
      on_exit(fn -> Application.delete_env(:engram, :qdrant_binary_quantization) end)

      Bypass.expect_once(bypass, "POST", "/collections/test_col/points/query", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        refute Map.has_key?(decoded, "params")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"result" => []}))
      end)

      vector = List.duplicate(0.1, 1024)
      assert {:ok, []} = Qdrant.search("test_col", vector, user_id: "1", limit: 5)
    end

    test "returns empty list when no results", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/test_col/points/query", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": []}))
      end)

      assert {:ok, []} = Qdrant.search("test_col", [0.1], user_id: "1", limit: 5)
    end

    test "parses object format with nested points key", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/test_col/points/query", fn conn ->
        resp = %{
          "result" => %{
            "points" => [
              %{
                "id" => "uuid-2",
                "score" => 0.88,
                "payload" => %{
                  "text" => "world",
                  "title" => "Doc",
                  "heading_path" => "Doc > Intro",
                  "source_path" => "Docs/Doc.md",
                  "tags" => ["research"],
                  "user_id" => "1"
                }
              }
            ]
          }
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end)

      vector = List.duplicate(0.1, 1024)
      assert {:ok, results} = Qdrant.search("test_col", vector, user_id: "1", limit: 5)
      assert length(results) == 1
      assert hd(results).score == 0.88
      assert hd(results).source_path == "Docs/Doc.md"
      assert hd(results).tags == ["research"]
    end

    test "returns error on failure", %{bypass: bypass} do
      Bypass.down(bypass)

      capture_log(fn ->
        assert {:error, _} = Qdrant.search("test_col", [0.1], user_id: "1", limit: 5)
      end)
    end
  end

  describe "delete_collection/1" do
    test "deletes a collection", %{bypass: bypass} do
      Bypass.expect_once(bypass, "DELETE", "/collections/test_col", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": true}))
      end)

      assert :ok = Qdrant.delete_collection("test_col")
    end

    test "returns ok when collection does not exist", %{bypass: bypass} do
      Bypass.expect_once(bypass, "DELETE", "/collections/test_col", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, ~s({"status":{"error":"Not found"}}))
      end)

      assert :ok = Qdrant.delete_collection("test_col")
    end
  end

  describe "collection_info/1" do
    test "returns collection config", %{bypass: bypass} do
      resp = %{
        "result" => %{
          "config" => %{
            "params" => %{
              "vectors" => %{"size" => 1024, "distance" => "Cosine"}
            }
          },
          "points_count" => 42
        }
      }

      Bypass.expect_once(bypass, "GET", "/collections/test_col", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end)

      assert {:ok, info} = Qdrant.collection_info("test_col")
      assert info["config"]["params"]["vectors"]["size"] == 1024
      assert info["points_count"] == 42
    end
  end

  describe "authentication" do
    test "sends api-key header when qdrant_api_key is configured", %{bypass: bypass} do
      Application.put_env(:engram, :qdrant_api_key, "test-qdrant-key")
      on_exit(fn -> Application.delete_env(:engram, :qdrant_api_key) end)

      Bypass.expect_once(bypass, "PUT", "/collections/test_col", fn conn ->
        api_key = Plug.Conn.get_req_header(conn, "api-key")
        assert api_key == ["test-qdrant-key"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": true}))
      end)

      assert :ok = Qdrant.ensure_collection("test_col", 1024)
    end

    test "does not send api-key header when config is not set", %{bypass: bypass} do
      Application.delete_env(:engram, :qdrant_api_key)

      Bypass.expect_once(bypass, "PUT", "/collections/test_col", fn conn ->
        api_key = Plug.Conn.get_req_header(conn, "api-key")
        assert api_key == []

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": true}))
      end)

      assert :ok = Qdrant.ensure_collection("test_col", 1024)
    end
  end
end
