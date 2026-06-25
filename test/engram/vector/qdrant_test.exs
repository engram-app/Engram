defmodule Engram.Vector.QdrantTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant

  setup do
    bypass = Bypass.open()
    # Per-process override (not global put_env) so this suite runs async.
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    # ensure_collection now creates payload indexes (#626); stub them so tests
    # asserting other behaviour don't trip on the index PUTs.
    stub_payload_indexes(bypass)
    %{bypass: bypass}
  end

  # Tolerate the keyword payload-index PUTs ensure_collection fires per field.
  defp stub_payload_indexes(bypass) do
    Bypass.stub(bypass, "PUT", "/collections/:col/index", fn conn ->
      Plug.Conn.send_resp(conn, 200, ~s({"status":"ok"}))
    end)
  end

  describe "ServiceConfig override" do
    test "prefers a per-process :qdrant_url override over global app env" do
      # `setup` points the global :qdrant_url at `bypass`. Install a per-process
      # override at a *different* Bypass and assert the request follows it —
      # proving the read goes through ServiceConfig (the async-safety seam).
      override_bypass = Bypass.open()
      Engram.ServiceConfig.put_override(:qdrant_url, "http://localhost:#{override_bypass.port}")
      stub_payload_indexes(override_bypass)

      Bypass.expect_once(override_bypass, "PUT", "/collections/ovr_col", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": true}))
      end)

      assert :ok = Qdrant.ensure_collection("ovr_col", 1024)
    end
  end

  describe "ensure_collection/2" do
    test "creates collection with named dense vector + keyword sparse(idf) + binary quantization config",
         %{bypass: bypass} do
      Bypass.expect_once(bypass, "PUT", "/collections/test_col", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["vectors"]["dense"]["size"] == 1024
        assert decoded["vectors"]["dense"]["distance"] == "Cosine"
        assert decoded["sparse_vectors"]["keyword"]["modifier"] == "idf"

        quant = decoded["quantization_config"]["binary"]
        assert quant["always_ram"] == true

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": true}))
      end)

      assert :ok = Qdrant.ensure_collection("test_col", 1024)
    end

    test "omits quantization config when binary quantization is disabled", %{bypass: bypass} do
      ServiceConfig.put_override(:qdrant_binary_quantization, false)

      Bypass.expect_once(bypass, "PUT", "/collections/test_col", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["vectors"]["dense"]["size"] == 1024
        assert decoded["vectors"]["dense"]["distance"] == "Cosine"
        assert decoded["sparse_vectors"]["keyword"]["modifier"] == "idf"
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

  describe "delete_payload_keys/2 (#590 backfill)" do
    test "posts a key-delete over a match-all filter", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/test_col/points/payload/delete", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert Enum.sort(decoded["keys"]) == ["folder", "source_path", "tags"]
        # Match-all selector: strip the keys from every existing point.
        assert decoded["filter"] == %{"must" => []}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": {"status": "completed"}}))
      end)

      assert :ok = Qdrant.delete_payload_keys("test_col", ["source_path", "folder", "tags"])
    end

    test "returns :ok on empty key list without HTTP call", %{bypass: bypass} do
      Bypass.stub(bypass, "POST", "/collections/test_col/points/payload/delete", fn _ ->
        flunk("delete_payload_keys must not call Qdrant for empty key list")
      end)

      assert :ok = Qdrant.delete_payload_keys("test_col", [])
    end

    test "delete_leaked_plaintext_keys/1 strips exactly source_path/folder/tags",
         %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/test_col/points/payload/delete", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Enum.sort(Jason.decode!(body)["keys"]) == ["folder", "source_path", "tags"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": {"status": "completed"}}))
      end)

      assert :ok = Qdrant.delete_leaked_plaintext_keys("test_col")
    end

    test "returns error on non-200 response", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/test_col/points/payload/delete", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, ~s({"status":{"error":"boom"}}))
      end)

      assert {:error, {500, _}} = Qdrant.delete_payload_keys("test_col", ["source_path"])
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
    test "posts filter delete keyed on path_hmac (T3.2)", %{bypass: bypass} do
      # T3.2 — Qdrant filter keys off `path_hmac` (HMAC base64) instead of
      # plaintext `source_path`. Plaintext path in `oban_jobs.args` would
      # have defeated Phase B at-rest encryption for the rename / delete
      # window; HMAC bytes are safe to JSON-encode.
      Bypass.expect_once(bypass, "POST", "/collections/test_col/points/delete", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        conditions = decoded["filter"]["must"]
        keys = Enum.map(conditions, & &1["key"])
        assert "user_id" in keys
        assert "vault_id" in keys
        assert "path_hmac" in keys
        refute "source_path" in keys

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": {"status": "ok"}}))
      end)

      assert :ok = Qdrant.delete_by_note("test_col", "user-1", "vault-1", "stub-hmac-base64")
    end
  end

  describe "count_by_note/4" do
    test "returns the exact point count for the filter", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/count", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["exact"] == true
        must = decoded["filter"]["must"]
        assert %{"key" => "path_hmac", "match" => %{"value" => "oldp=="}} in must

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": {"count": 3}}))
      end)

      assert {:ok, 3} = Qdrant.count_by_note("engram_notes", "7", "9", "oldp==")
    end

    test "returns {:error, _} on non-200", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/count", fn conn ->
        Plug.Conn.send_resp(conn, 503, ~s({"status":"error"}))
      end)

      assert {:error, {503, _}} = Qdrant.count_by_note("engram_notes", "7", "9", "oldp==")
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
      ServiceConfig.put_override(:qdrant_binary_quantization, false)

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

  describe "collection_name/0" do
    test "returns the configured collection name" do
      assert is_binary(Qdrant.collection_name())
    end

    test "is a public function with arity 0" do
      assert function_exported?(Engram.Vector.Qdrant, :collection_name, 0)
    end
  end

  describe "scroll/2" do
    test "is a public function with arity 2" do
      assert function_exported?(Engram.Vector.Qdrant, :scroll, 2)
    end

    test "posts to points/scroll with filter, returns points and next_page_offset", %{
      bypass: bypass
    } do
      points = [
        %{"id" => "uuid-1", "payload" => %{"user_id" => 42, "text" => "hello"}}
      ]

      Bypass.expect_once(bypass, "POST", "/collections/test_col/points/scroll", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["with_payload"] == true
        assert decoded["with_vector"] == false
        assert decoded["limit"] == 200

        filter = decoded["filter"]["must"]
        assert length(filter) == 1
        assert hd(filter)["key"] == "user_id"
        assert hd(filter)["match"]["value"] == 42

        resp = %{"result" => %{"points" => points, "next_page_offset" => nil}}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end)

      filter = %{must: [%{key: "user_id", match: %{value: 42}}]}
      assert {:ok, result} = Qdrant.scroll("test_col", filter: filter)
      assert result.points == points
      assert is_nil(result.next_page_offset)
    end

    test "sends offset when provided", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/test_col/points/scroll", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["offset"] == "uuid-cursor"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"result" => %{"points" => [], "next_page_offset" => nil}})
        )
      end)

      filter = %{must: [%{key: "user_id", match: %{value: 1}}]}
      assert {:ok, _} = Qdrant.scroll("test_col", filter: filter, offset: "uuid-cursor")
    end

    test "omits offset key when nil (first page)", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/test_col/points/scroll", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        refute Map.has_key?(decoded, "offset")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"result" => %{"points" => [], "next_page_offset" => nil}})
        )
      end)

      filter = %{must: [%{key: "user_id", match: %{value: 1}}]}
      assert {:ok, _} = Qdrant.scroll("test_col", filter: filter)
    end

    test "returns next_page_offset when more pages exist", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/test_col/points/scroll", fn conn ->
        resp = %{
          "result" => %{
            "points" => [%{"id" => "uuid-1", "payload" => %{}}],
            "next_page_offset" => "uuid-1"
          }
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end)

      filter = %{must: [%{key: "user_id", match: %{value: 1}}]}
      assert {:ok, result} = Qdrant.scroll("test_col", filter: filter)
      assert result.next_page_offset == "uuid-1"
    end

    test "returns error on non-200 response", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/test_col/points/scroll", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, ~s({"status": {"error": "bad filter"}}))
      end)

      filter = %{must: [%{key: "user_id", match: %{value: 1}}]}
      assert {:error, {:qdrant_scroll, 400, _}} = Qdrant.scroll("test_col", filter: filter)
    end

    test "returns error on connection failure", %{bypass: bypass} do
      Bypass.down(bypass)

      capture_log(fn ->
        filter = %{must: [%{key: "user_id", match: %{value: 1}}]}
        assert {:error, _} = Qdrant.scroll("test_col", filter: filter)
      end)
    end
  end

  describe "search_body/2 — body builder (no HTTP)" do
    test "sets with_vector when requested" do
      body = Qdrant.search_body(%{some: :vec}, user_id: "u1", with_vector: true)
      assert body.with_vector == ["dense"]
    end

    test "does not set with_vector by default" do
      body = Qdrant.search_body(%{some: :vec}, user_id: "u1")
      refute Map.has_key?(body, :with_vector)
    end

    test "uses quantization ignore when full_precision" do
      body = Qdrant.search_body(%{some: :vec}, user_id: "u1", full_precision: true)
      assert body.params.quantization == %{ignore: true}
    end

    test "defaults to rescore when not full_precision (binary quant enabled by default)" do
      body = Qdrant.search_body(%{some: :vec}, user_id: "u1")
      assert body.params.quantization == %{rescore: true, oversampling: 3.0}
    end

    test "omits params entirely when binary quantization is disabled" do
      ServiceConfig.put_override(:qdrant_binary_quantization, false)
      body = Qdrant.search_body(%{some: :vec}, user_id: "u1")
      refute Map.has_key?(body, :params)
    end

    test "full_precision overrides binary-quant-disabled — still sets ignore" do
      ServiceConfig.put_override(:qdrant_binary_quantization, false)
      body = Qdrant.search_body(%{some: :vec}, user_id: "u1", full_precision: true)
      assert body.params.quantization == %{ignore: true}
    end
  end

  describe "sparse_search_body/2 — body builder (no HTTP)" do
    test "sets with_vector when requested" do
      sparse = %{indices: [1, 2], values: [0.5, 0.3]}
      body = Qdrant.sparse_search_body(sparse, user_id: "u1", with_vector: true)
      assert body.with_vector == ["dense"]
    end

    test "does not set with_vector by default" do
      sparse = %{indices: [1, 2], values: [0.5, 0.3]}
      body = Qdrant.sparse_search_body(sparse, user_id: "u1")
      refute Map.has_key?(body, :with_vector)
    end

    test "does not add quantization params (sparse leg has no quant config)" do
      sparse = %{indices: [1, 2], values: [0.5, 0.3]}
      body = Qdrant.sparse_search_body(sparse, user_id: "u1")
      refute Map.has_key?(body, :params)
    end
  end

  describe "hybrid_search_body/3 — body builder (no HTTP)" do
    test "sets with_vector at top level when requested" do
      dense = List.duplicate(0.1, 4)
      sparse = %{indices: [1, 2], values: [0.5, 0.3]}
      body = Qdrant.hybrid_search_body(dense, sparse, user_id: "u1", with_vector: true)
      assert body.with_vector == ["dense"]
    end

    test "does not set with_vector at top level by default" do
      dense = List.duplicate(0.1, 4)
      sparse = %{indices: [1, 2], values: [0.5, 0.3]}
      body = Qdrant.hybrid_search_body(dense, sparse, user_id: "u1")
      refute Map.has_key?(body, :with_vector)
    end

    test "puts quantization params on dense prefetch leg only when full_precision" do
      dense = List.duplicate(0.1, 4)
      sparse = %{indices: [1, 2], values: [0.5, 0.3]}
      body = Qdrant.hybrid_search_body(dense, sparse, user_id: "u1", full_precision: true)
      [dense_leg, sparse_leg] = body.prefetch
      assert dense_leg.params.quantization == %{ignore: true}
      refute Map.has_key?(sparse_leg, :params)
    end

    test "puts rescore params on dense prefetch leg only (default binary quant)" do
      dense = List.duplicate(0.1, 4)
      sparse = %{indices: [1, 2], values: [0.5, 0.3]}
      body = Qdrant.hybrid_search_body(dense, sparse, user_id: "u1")
      [dense_leg, sparse_leg] = body.prefetch
      assert dense_leg.params.quantization == %{rescore: true, oversampling: 3.0}
      refute Map.has_key?(sparse_leg, :params)
    end

    test "does not put quantization params on either leg when binary quant disabled" do
      ServiceConfig.put_override(:qdrant_binary_quantization, false)
      dense = List.duplicate(0.1, 4)
      sparse = %{indices: [1, 2], values: [0.5, 0.3]}
      body = Qdrant.hybrid_search_body(dense, sparse, user_id: "u1")
      [dense_leg, sparse_leg] = body.prefetch
      refute Map.has_key?(dense_leg, :params)
      refute Map.has_key?(sparse_leg, :params)
    end
  end

  describe "do_search result parser — :vector key" do
    test "parsed result includes :vector key from vector.dense when present", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/test_col/points/query", fn conn ->
        resp = %{
          "result" => [
            %{
              "id" => "uuid-1",
              "score" => 0.95,
              "payload" => %{"text" => "hello", "title" => "Note"},
              "vector" => %{"dense" => [0.1, 0.2, 0.3]}
            }
          ]
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end)

      vector = List.duplicate(0.1, 1024)
      assert {:ok, [result]} = Qdrant.search("test_col", vector, user_id: "1", limit: 5)
      assert result.vector == [0.1, 0.2, 0.3]
    end

    test "parsed result has no :vector key when vector is absent from response",
         %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/test_col/points/query", fn conn ->
        resp = %{
          "result" => [
            %{
              "id" => "uuid-1",
              "score" => 0.9,
              "payload" => %{"text" => "hello"}
            }
          ]
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end)

      vector = List.duplicate(0.1, 1024)
      assert {:ok, [result]} = Qdrant.search("test_col", vector, user_id: "1", limit: 5)
      # nil values are stripped by Enum.reject in do_search, so :vector absent
      refute Map.has_key?(result, :vector)
    end
  end

  describe "set_payload_by_filter/5" do
    test "PATCHes payload on points matching the user/vault/path_hmac filter", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/payload", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["payload"] == %{"path_hmac" => "newp==", "folder_hmac" => "newf=="}

        must = decoded["filter"]["must"]
        assert %{"key" => "user_id", "match" => %{"value" => "7"}} in must
        assert %{"key" => "vault_id", "match" => %{"value" => "9"}} in must
        assert %{"key" => "path_hmac", "match" => %{"value" => "oldp=="}} in must
        # No explicit point-id list — this is a filter-scoped patch.
        refute Map.has_key?(decoded, "points")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": true}))
      end)

      assert :ok =
               Qdrant.set_payload_by_filter("engram_notes", "7", "9", "oldp==", %{
                 "path_hmac" => "newp==",
                 "folder_hmac" => "newf=="
               })
    end

    test "returns {:error, {status, body}} on non-200", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/payload", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, ~s({"status":"error"}))
      end)

      assert {:error, {500, _}} =
               Qdrant.set_payload_by_filter("engram_notes", "7", "9", "oldp==", %{
                 "path_hmac" => "x"
               })
    end

    # Tenant-isolation guard (#746): even if two users' folded path_hmacs
    # collide, the filter is scoped by the caller's user_id + vault_id, so a
    # PATCH for user 7 can never touch user 8's points. The typed required
    # args make a path_hmac-only filter impossible to express.
    test "scopes the PATCH to the caller's user_id/vault_id (no cross-tenant)", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/payload", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        must = Jason.decode!(body)["filter"]["must"]

        assert %{"key" => "user_id", "match" => %{"value" => "7"}} in must
        assert %{"key" => "vault_id", "match" => %{"value" => "9"}} in must
        # Crucially NOT user 8 — the colliding tenant.
        refute %{"key" => "user_id", "match" => %{"value" => "8"}} in must

        Plug.Conn.send_resp(conn, 200, ~s({"result": true}))
      end)

      # Same colliding path_hmac "collide==" as a hypothetical user 8 — still scoped to 7/9.
      assert :ok =
               Qdrant.set_payload_by_filter("engram_notes", "7", "9", "collide==", %{
                 "path_hmac" => "x"
               })
    end
  end

  describe "authentication" do
    test "sends api-key header when qdrant_api_key is configured", %{bypass: bypass} do
      ServiceConfig.put_override(:qdrant_api_key, "test-qdrant-key")

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
      # No override + app env unset (runtime-only key) ⇒ no api-key header.
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
