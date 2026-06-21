defmodule EngramWeb.SearchControllerTest do
  use EngramWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Mox

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user, is_default: true)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    grant_api_write!(user)
    authed = put_req_header(conn, "authorization", "Bearer #{api_key}")

    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    %{conn: authed, user: user, vault: vault, bypass: bypass}
  end

  describe "POST /search" do
    test "returns results for a valid query", %{
      conn: conn,
      bypass: bypass,
      user: user,
      vault: vault
    } do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      {:ok, enc} =
        Engram.Crypto.encrypt_qdrant_payload(
          %{text: "Ferritin levels.", title: "Iron Panel", heading_path: "Iron Panel"},
          user,
          "engram_notes",
          "uuid-1"
        )

      qdrant_result = %{
        "result" => [
          %{
            "id" => "uuid-1",
            "score" => 0.95,
            "payload" => %{
              "text" => enc.text,
              "title" => enc.title,
              "heading_path" => enc.heading_path,
              "text_nonce" => enc.text_nonce,
              "title_nonce" => enc.title_nonce,
              "heading_path_nonce" => enc.heading_path_nonce,
              "aad_version" => enc.aad_version,
              "source_path" => "Health/Iron Panel.md",
              "tags" => ["health"],
              "user_id" => to_string(user.id),
              "vault_id" => to_string(vault.id)
            }
          }
        ]
      }

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn c ->
        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(qdrant_result))
      end)

      conn = post(conn, "/api/search", %{query: "iron panel"})
      assert %{"results" => results} = json_response(conn, 200)
      assert length(results) == 1
      [hit] = results
      assert hit["score"] == 0.95
      assert hit["path"] == "Health/Iron Panel.md"
      assert hit["title"] == "Iron Panel"
      assert hit["folder"] == "Health"
      assert hit["snippet"] == "Ferritin levels."
      assert hit["match_count"] == 1
    end

    test "includes numeric id on a search hit when the note exists in PG", %{
      conn: conn,
      bypass: bypass,
      user: user,
      vault: vault
    } do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      # Mirror prod: the note must exist in PG (with an id) for the search
      # controller's path→id lookup to resolve. Qdrant chunks for orphan
      # paths fall back to id: nil — covered separately below.
      {:ok, note} =
        Engram.Notes.upsert_note(user, vault, %{
          "path" => "Health/Iron Panel.md",
          "content" => "# Iron Panel\n\nFerritin levels.",
          "mtime" => 1_000.0
        })

      {:ok, enc} =
        Engram.Crypto.encrypt_qdrant_payload(
          %{text: "Ferritin levels.", title: "Iron Panel", heading_path: "Iron Panel"},
          user,
          "engram_notes",
          "uuid-1"
        )

      qdrant_result = %{
        "result" => [
          %{
            "id" => "uuid-1",
            "score" => 0.95,
            "payload" => %{
              "text" => enc.text,
              "title" => enc.title,
              "heading_path" => enc.heading_path,
              "text_nonce" => enc.text_nonce,
              "title_nonce" => enc.title_nonce,
              "heading_path_nonce" => enc.heading_path_nonce,
              "aad_version" => enc.aad_version,
              "source_path" => "Health/Iron Panel.md",
              "tags" => ["health"],
              "user_id" => to_string(user.id),
              "vault_id" => to_string(vault.id)
            }
          }
        ]
      }

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn c ->
        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(qdrant_result))
      end)

      conn = post(conn, "/api/search", %{query: "iron panel"})
      assert %{"results" => [hit]} = json_response(conn, 200)
      assert hit["id"] == note.id
      assert is_binary(hit["id"])
    end

    test "over-fetches chunks so grouping can return the requested number of notes",
         %{conn: conn, bypass: bypass} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn c ->
        {:ok, body, c} = Plug.Conn.read_body(c)
        decoded = Jason.decode!(body)
        # Client requests 10 notes → controller asks Qdrant for 40 chunks
        # (10 * @overfetch_factor) so multiple chunks per note don't cap
        # the visible result set below 10 notes.
        assert decoded["limit"] == 40

        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": []}))
      end)

      conn = post(conn, "/api/search", %{query: "test", limit: 10})
      assert %{"results" => []} = json_response(conn, 200)
    end

    test "web search requests hybrid mode", %{conn: conn, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn c ->
        {:ok, body, c} = Plug.Conn.read_body(c)
        assert Jason.decode!(body)["query"]["fusion"] == "rrf"

        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result":{"points":[]}}))
      end)

      Engram.MockEmbedder |> expect(:embed_texts, fn ["hi"], _ -> {:ok, [[0.1, 0.2, 0.3]]} end)

      conn = post(conn, ~p"/api/search", %{"query" => "hi"})
      assert json_response(conn, 200)["results"] == []
    end

    test "?mode=vector issues a single-leg dense query without prefetch", %{
      conn: conn,
      bypass: bypass
    } do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn c ->
        {:ok, body, c} = Plug.Conn.read_body(c)
        json = Jason.decode!(body)
        assert json["using"] == "dense"
        refute Map.has_key?(json, "prefetch")

        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result":[]}))
      end)

      conn = post(conn, ~p"/api/search", %{"query" => "ferritin", "mode" => "vector"})
      assert json_response(conn, 200)["results"] == []
    end

    test "?mode=garbage falls back to hybrid (rrf fusion)", %{conn: conn, bypass: bypass} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn c ->
        {:ok, body, c} = Plug.Conn.read_body(c)
        assert Jason.decode!(body)["query"]["fusion"] == "rrf"

        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result":{"points":[]}}))
      end)

      conn = post(conn, ~p"/api/search", %{"query" => "ferritin", "mode" => "garbage"})
      assert json_response(conn, 200)["results"] == []
    end

    test "returns 422 when query is missing", %{conn: conn} do
      conn = post(conn, "/api/search", %{})
      assert json_response(conn, 422)
    end

    test "clamps note limit then over-fetches chunks", %{conn: conn, bypass: bypass} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn c ->
        {:ok, body, c} = Plug.Conn.read_body(c)
        decoded = Jason.decode!(body)
        # 999 notes → clamped to 50 → 50 * 4 = 200 chunks asked of Qdrant.
        assert decoded["limit"] == 200

        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": []}))
      end)

      conn = post(conn, "/api/search", %{query: "test", limit: 999})
      assert json_response(conn, 200)
    end

    test "returns 401 without auth", %{conn: conn} do
      conn =
        conn
        |> delete_req_header("authorization")
        |> post("/api/search", %{query: "test"})

      assert json_response(conn, 401)
    end

    test "does not leak internal details on search error", %{conn: conn, bypass: bypass} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      Bypass.expect(bypass, "POST", "/collections/engram_notes/points/query", fn c ->
        Plug.Conn.send_resp(c, 500, ~s({"status":{"error":"Qdrant internal"}}))
      end)

      {conn, _log} =
        with_log(fn ->
          post(conn, "/api/search", %{query: "test"})
        end)

      body = json_response(conn, 500)
      # Must NOT contain internal Elixir terms or adapter details
      refute String.contains?(body["error"], "Qdrant")
      refute String.contains?(body["error"], "%{")
      refute String.contains?(body["error"], "Elixir")
    end

    test "returns empty results list when nothing found", %{conn: conn, bypass: bypass} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn c ->
        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": []}))
      end)

      conn = post(conn, "/api/search", %{query: "nothing here"})
      assert %{"results" => []} = json_response(conn, 200)
    end

    test "groups repeated chunks from the same note into one result with match_count",
         %{conn: conn, bypass: bypass, user: user} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      # Three top hits all point at the same note plus one different note —
      # before the over-fetch + group_by_note fix, repeated chunks would
      # crowd out the second note even though there were enough candidates.
      qdrant_result = %{
        "result" => [
          chunk("uuid-a1", 0.95, "Health/Iron Panel.md", "Iron Panel", "Ferritin section.", user),
          chunk("uuid-a2", 0.91, "Health/Iron Panel.md", "Iron Panel", "TIBC section.", user),
          chunk(
            "uuid-a3",
            0.88,
            "Health/Iron Panel.md",
            "Iron Panel",
            "Notes on saturation.",
            user
          ),
          chunk("uuid-b1", 0.80, "Health/Vitamin D.md", "Vitamin D", "Levels by season.", user)
        ]
      }

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn c ->
        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(qdrant_result))
      end)

      conn = post(conn, "/api/search", %{query: "iron", limit: 5})
      assert %{"results" => results} = json_response(conn, 200)

      # Two unique notes, sorted by best chunk score.
      assert length(results) == 2
      [iron, vitd] = results

      assert iron["path"] == "Health/Iron Panel.md"
      assert iron["match_count"] == 3
      assert iron["snippet"] == "Ferritin section."
      assert iron["score"] == 0.95

      assert vitd["path"] == "Health/Vitamin D.md"
      assert vitd["match_count"] == 1
    end

    test "passes diversity=0.5 to Search — Qdrant query requests vectors (MMR path)", %{
      conn: conn,
      bypass: bypass,
      user: user,
      vault: vault
    } do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn c ->
        {:ok, body, c} = Plug.Conn.read_body(c)
        decoded = Jason.decode!(body)
        # diversity > 0 triggers the MMR path: Search requests dense vectors from
        # Qdrant so MMR can compare cosine similarity between candidates.
        assert decoded["with_vector"] == ["dense"],
               "expected with_vector: [\"dense\"] when diversity=0.5, got: #{inspect(decoded["with_vector"])}"

        # Return a valid point with a dense vector so the MMR pipeline succeeds.
        points = [diverse_chunk(user, vault, "mmr-1", 0.9, [1.0, 0.0], "MMR result")]

        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"result" => points}))
      end)

      conn = post(conn, ~p"/api/search", %{"query" => "hello", "diversity" => "0.5"})
      assert json_response(conn, 200)
    end

    test "out-of-range diversity=5 is clamped downstream — still returns 200", %{
      conn: conn,
      bypass: bypass
    } do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      # diversity=5 is parsed as a float and passed to Search; Search clamps it
      # to 1.0. The request is still valid and returns a 200 with results.
      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn c ->
        {:ok, _body, c} = Plug.Conn.read_body(c)

        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result":[]}))
      end)

      conn = post(conn, ~p"/api/search", %{"query" => "hello", "diversity" => "5"})
      assert json_response(conn, 200)
    end

    test "unparseable diversity is silently ignored — still returns 200", %{
      conn: conn,
      bypass: bypass
    } do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      # diversity="not-a-float" → parse error → key omitted → profile default
      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn c ->
        {:ok, _body, c} = Plug.Conn.read_body(c)

        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result":[]}))
      end)

      conn = post(conn, ~p"/api/search", %{"query" => "hello", "diversity" => "not-a-float"})
      assert json_response(conn, 200)
    end

    test "honors the requested note limit when more unique notes are available",
         %{conn: conn, bypass: bypass, user: user} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      result = %{
        "result" =>
          for i <- 1..10 do
            chunk(
              "uuid-#{i}",
              1.0 - i * 0.01,
              "F/Note #{i}.md",
              "Note #{i}",
              "snippet #{i}",
              user
            )
          end
      }

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn c ->
        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(result))
      end)

      conn = post(conn, "/api/search", %{query: "note", limit: 3})
      %{"results" => results} = json_response(conn, 200)
      assert length(results) == 3
    end
  end

  defp chunk(id, score, source_path, title, text, user) do
    chunk(id, score, source_path, title, text, user, default_vault_id(user))
  end

  defp chunk(id, score, source_path, title, text, user, vault_id) do
    {:ok, enc} =
      Engram.Crypto.encrypt_qdrant_payload(
        %{text: text, title: title, heading_path: title},
        user,
        "engram_notes",
        id
      )

    %{
      "id" => id,
      "score" => score,
      "payload" => %{
        "text" => enc.text,
        "title" => enc.title,
        "heading_path" => enc.heading_path,
        "text_nonce" => enc.text_nonce,
        "title_nonce" => enc.title_nonce,
        "heading_path_nonce" => enc.heading_path_nonce,
        "aad_version" => enc.aad_version,
        "source_path" => source_path,
        "tags" => [],
        "user_id" => to_string(user.id),
        "vault_id" => to_string(vault_id)
      }
    }
  end

  defp default_vault_id(user) do
    user
    |> Engram.Vaults.list_vaults()
    |> Enum.find(& &1.is_default)
    |> Map.fetch!(:id)
  end

  # Like `chunk/6` but includes a dense vector so the MMR path can run
  # (diversity > 0 requests `with_vector: ["dense"]` from Qdrant and MMR
  # then calls cosine similarity on the returned vectors).
  defp diverse_chunk(user, vault, qid, score, vector, text) do
    {:ok, enc} =
      Engram.Crypto.encrypt_qdrant_payload(
        %{text: text, title: qid, heading_path: qid},
        user,
        "engram_notes",
        qid
      )

    %{
      "id" => qid,
      "score" => score,
      "vector" => %{"dense" => vector},
      "payload" => %{
        "text" => enc.text,
        "title" => enc.title,
        "heading_path" => enc.heading_path,
        "text_nonce" => enc.text_nonce,
        "title_nonce" => enc.title_nonce,
        "heading_path_nonce" => enc.heading_path_nonce,
        "aad_version" => enc.aad_version,
        "source_path" => "#{qid}.md",
        "tags" => [],
        "user_id" => to_string(user.id),
        "vault_id" => to_string(vault.id)
      }
    }
  end
end
