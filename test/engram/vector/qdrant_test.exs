defmodule Engram.Vector.QdrantTest do
  use ExUnit.Case, async: true

  import Engram.QdrantFilterView

  import ExUnit.CaptureLog

  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant

  setup do
    bypass = Bypass.open()
    # Per-process override (not global put_env) so this suite runs async.
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    # Search fails fast at 5s (a prod budget). Under full-suite load a Bypass
    # reply can starve past it and read as a Req timeout, not a real failure
    # (same pin as qdrant_hybrid_test / qdrant_req_opts_test, #886).
    ServiceConfig.put_override(:qdrant_search_timeout, 30_000)
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
        conditions = legacy_view(decoded["filter"]["must"])
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
        keys = Enum.map(legacy_view(decoded["filter"]["must"]), & &1["key"])

        refute "source_path" in keys

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": {"status": "ok"}}))
      end)

      assert :ok = Qdrant.delete_by_vault("test_col", "user-1", "vault-1")
    end
  end

  describe "delete_by_note/4" do
    # R3b: every point carries `n` (the prod ledger is closed; an R3a point
    # has no `p`), and the `p`/`path_hmac` indexes are retired, so the belt is
    # the tenant plus the note id: no path condition, no index probe.
    test "posts a filter delete on the tenant and n alone", %{bypass: bypass} do
      note_id = "33333333-3333-3333-3333-333333333333"

      Bypass.expect_once(bypass, "POST", "/collections/test_col/points/delete", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        filter = Jason.decode!(body)["filter"]
        keys = Enum.map(legacy_view(filter["must"]), & &1["key"])
        assert "user_id" in keys
        assert "vault_id" in keys

        assert %{"key" => "n", "match" => %{"value" => Engram.Vector.FilterId.uuid(note_id)}} in filter[
                 "must"
               ]

        for key <- ~w(p path_hmac source_path), do: refute(inspect(filter) =~ ~s("#{key}"))
        refute inspect(filter) =~ "is_empty"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": {"status": "ok"}}))
      end)

      assert :ok = Qdrant.delete_by_note("test_col", "user-1", "vault-1", note_id)
    end
  end

  # Qdrant answers 404 when the COLLECTION is absent, which means there is
  # nothing to delete. Returning an error there makes DeleteNoteIndex (#1608,
  # which now retries instead of swallowing) burn its attempts and discard on
  # a fresh self-host or dev stack that has never indexed anything. Missing
  # point ids are not this case: those come back 200.
  describe "deletes against a missing collection" do
    test "delete_points/2 treats 404 as nothing to delete", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/test_col/points/delete", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, ~s({"status":{"error":"Collection not found"}}))
      end)

      assert :ok = Qdrant.delete_points("test_col", [Ecto.UUID.generate()])
    end

    test "delete_by_note/4 treats 404 as nothing to delete", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/test_col/points/delete", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, ~s({"status":{"error":"Collection not found"}}))
      end)

      assert :ok =
               Qdrant.delete_by_note(
                 "test_col",
                 "user-1",
                 "vault-1",
                 "33333333-3333-3333-3333-333333333333"
               )
    end

    test "a 500 is still an error", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/test_col/points/delete", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, ~s({"status":{"error":"boom"}}))
      end)

      assert {:error, {500, _}} = Qdrant.delete_points("test_col", [Ecto.UUID.generate()])
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

    # The body is decoded in Rust (Engram.Native.json_decode/1); the error
    # shapes callers match on are unchanged.
    test "a 200 with a malformed body is an error carrying the raw text", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/test_col/points/query", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": [))
      end)

      assert {:error, {200, ~s({"result": [)}} =
               Qdrant.search("test_col", List.duplicate(0.1, 4), user_id: "1", limit: 5)
    end

    test "a 200 without a result key is an error carrying the decoded body", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/test_col/points/query", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"status": "ok"}))
      end)

      assert {:error, {200, %{"status" => "ok"}}} =
               Qdrant.search("test_col", List.duplicate(0.1, 4), user_id: "1", limit: 5)
    end

    # As Req's own decoding did: by content type, not by whether it parses.
    test "an error body is decoded only when it is JSON by content type", %{bypass: bypass} do
      for {type, body, expected} <- [
            {"application/json", ~s({"status":{"error":"bad"}}),
             %{"status" => %{"error" => "bad"}}},
            {"text/plain", "404", "404"},
            {"text/plain", "gateway down", "gateway down"}
          ] do
        Bypass.expect_once(bypass, "POST", "/collections/test_col/points/query", fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type(type)
          |> Plug.Conn.send_resp(400, body)
        end)

        assert {:error, {400, ^expected}} =
                 Qdrant.search("test_col", List.duplicate(0.1, 4), user_id: "1", limit: 5)
      end
    end

    test "dense vectors come back as float lists, integral values as integers",
         %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/test_col/points/query", fn conn ->
        body = ~s({"result":[{"id":"u","score":1,"payload":{},"vector":{"dense":[0.25,0,-1.5]}}]})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end)

      assert {:ok, [%{score: 1, vector: [0.25, 0, -1.5]}]} =
               Qdrant.search("test_col", List.duplicate(0.1, 4), user_id: "1", limit: 5)
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
      # ensure_loaded? first: function_exported?/3 answers false for a module
      # that simply has not been LOADED yet, which under CI's test ordering is
      # a coin flip rather than a statement about the module.
      assert Code.ensure_loaded?(Engram.Vector.Qdrant)
      assert function_exported?(Engram.Vector.Qdrant, :collection_name, 0)
    end
  end

  describe "scroll/2" do
    test "is a public function with arity 2" do
      # See collection_name/0 above — without ensure_loaded? this asserts on
      # module load order, and it went red in CI while the scroll/2 HTTP test
      # directly below it passed.
      assert Code.ensure_loaded?(Engram.Vector.Qdrant)
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

        # Task 15.7: no payload unless the caller names the keys.
        assert decoded["with_payload"] == false
        assert decoded["with_vector"] == false
        assert decoded["limit"] == 200

        filter = legacy_view(decoded["filter"]["must"])
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

  # OrphanSweep's tenant discovery (prod 2026-11-16: the payload scroll it
  # replaces was ~2.7k requests and ~550 MB of payload reads a run).
  describe "facet_values/2" do
    defp facet_hits(conn, values) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "result" => %{"hits" => Enum.map(values, &%{"value" => &1, "count" => 1})}
        })
      )
    end

    test "one exact facet request on the key, capped at max_page, no payload", %{
      bypass: bypass
    } do
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/collections/test_col/facet", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:facet, Jason.decode!(body)})
        facet_hits(conn, ["a", "b"])
      end)

      assert {:ok, ["a", "b"]} = Qdrant.facet_values("test_col", "u")
      assert_received {:facet, body}
      assert body == %{"key" => "u", "limit" => Qdrant.max_page(), "exact" => true}
    end

    # Qdrant facet has no offset. A full page may have cut values off, so the
    # next request excludes every value already seen, in `max_ids/0` chunks
    # (the Cloud `condition_max_size`), until a short page.
    test "pages past a full response by excluding the values already seen", %{bypass: bypass} do
      first = for i <- 1..Qdrant.max_page(), do: "v#{i}"
      test_pid = self()

      Bypass.expect(bypass, "POST", "/collections/test_col/facet", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        send(test_pid, {:facet, decoded})

        if decoded["filter"], do: facet_hits(conn, ["last"]), else: facet_hits(conn, first)
      end)

      assert {:ok, values} = Qdrant.facet_values("test_col", "u")
      assert Enum.sort(values) == Enum.sort(["last" | first])

      assert_received {:facet, first_body}
      refute Map.has_key?(first_body, "filter")

      assert_received {:facet, %{"filter" => %{"must_not" => conditions}}}
      assert Enum.all?(conditions, &(&1["key"] == "u"))
      assert Enum.all?(conditions, &(length(&1["match"]["any"]) <= Qdrant.max_ids()))
      assert conditions |> Enum.flat_map(& &1["match"]["any"]) |> Enum.sort() == Enum.sort(first)
    end

    test "exactly max_page values costs one extra, empty request", %{bypass: bypass} do
      first = for i <- 1..Qdrant.max_page(), do: "v#{i}"
      count = :counters.new(1, [])

      Bypass.expect(bypass, "POST", "/collections/test_col/facet", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        :counters.add(count, 1, 1)
        facet_hits(conn, if(Jason.decode!(body)["filter"], do: [], else: first))
      end)

      assert {:ok, values} = Qdrant.facet_values("test_col", "u")
      assert length(values) == Qdrant.max_page()
      assert :counters.get(count, 1) == 2
    end

    # Exact facet counts only visible points, so an index entry left behind
    # by deleted points answers count 0 (staging 2026-11-16: 4 such tenant
    # ids). It is no value of the key. Hits come back count-descending, so a
    # 0 means every later value is 0 too: the walk stops there, and no 0 is
    # carried into the next page's exclusion list.
    test "drops count-0 hits and stops paging at the first", %{bypass: bypass} do
      live = for i <- 1..(Qdrant.max_page() - 2), do: "v#{i}"
      count = :counters.new(1, [])

      Bypass.expect(bypass, "POST", "/collections/test_col/facet", fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)
        :counters.add(count, 1, 1)

        hits =
          Enum.map(live, &%{"value" => &1, "count" => 3}) ++
            [%{"value" => "gone1", "count" => 0}, %{"value" => "gone2"}]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"result" => %{"hits" => hits}}))
      end)

      assert {:ok, values} = Qdrant.facet_values("test_col", "u")
      assert Enum.sort(values) == Enum.sort(live)
      assert :counters.get(count, 1) == 1
    end

    test "a non-200 is an error, never a partial set", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/test_col/facet", fn conn ->
        Plug.Conn.send_resp(conn, 400, ~s({"status":{"error":"bad"}}))
      end)

      assert {:error, {:qdrant_facet, 400, _}} = Qdrant.facet_values("test_col", "u")
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
    # Fusion needs ids and scores only. Payload and vectors are fetched for
    # the fused points alone (the retrieve in hybrid_search/4).
    test "the legs ask for no payload and no vector, even with with_vector" do
      dense = List.duplicate(0.1, 4)
      sparse = %{indices: [1, 2], values: [0.5, 0.3]}

      for opts <- [[user_id: "u1"], [user_id: "u1", with_vector: true]] do
        body = Qdrant.hybrid_search_body(dense, sparse, opts)
        assert length(body.searches) == 2
        assert Enum.all?(body.searches, &(&1.with_payload == false))
        refute Enum.any?(body.searches, &Map.has_key?(&1, :with_vector))
      end
    end

    test "puts quantization params on the dense leg only when full_precision" do
      dense = List.duplicate(0.1, 4)
      sparse = %{indices: [1, 2], values: [0.5, 0.3]}
      body = Qdrant.hybrid_search_body(dense, sparse, user_id: "u1", full_precision: true)
      [dense_leg, sparse_leg] = body.searches
      assert dense_leg.params.quantization == %{ignore: true}
      refute Map.has_key?(sparse_leg, :params)
    end

    test "puts rescore params on the dense leg only (default binary quant)" do
      dense = List.duplicate(0.1, 4)
      sparse = %{indices: [1, 2], values: [0.5, 0.3]}
      body = Qdrant.hybrid_search_body(dense, sparse, user_id: "u1")
      [dense_leg, sparse_leg] = body.searches
      assert dense_leg.params.quantization == %{rescore: true, oversampling: 3.0}
      refute Map.has_key?(sparse_leg, :params)
    end

    test "does not put quantization params on either leg when binary quant disabled" do
      ServiceConfig.put_override(:qdrant_binary_quantization, false)
      dense = List.duplicate(0.1, 4)
      sparse = %{indices: [1, 2], values: [0.5, 0.3]}
      body = Qdrant.hybrid_search_body(dense, sparse, user_id: "u1")
      [dense_leg, sparse_leg] = body.searches
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
