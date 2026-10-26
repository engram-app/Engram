defmodule EngramWeb.SearchControllerTest do
  use EngramWeb.ConnCase, async: false

  import Engram.QdrantFilterView

  import ExUnit.CaptureLog
  import Mox

  alias Engram.QdrantStub

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user, is_default: true)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    lift_api_rps_cap!(user)
    authed = put_req_header(conn, "authorization", "Bearer #{api_key}")

    bypass = Bypass.open()

    Engram.QdrantStub.stub_retrieve(bypass)
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    %{conn: authed, user: user, vault: vault, bypass: bypass}
  end

  describe "input limits" do
    test "an over-long query is a 422 naming the limit", %{conn: conn} do
      long = String.duplicate("a", Engram.Search.max_query_bytes() + 1)
      conn = post(conn, ~p"/api/search", %{"query" => long})
      assert %{"error" => error} = json_response(conn, 422)
      assert error =~ "query"
    end

    test "too many tags is a 422 naming the limit", %{conn: conn} do
      tags = for i <- 1..(Engram.Vector.Qdrant.max_ids() + 1), do: "t#{i}"
      conn = post(conn, ~p"/api/search", %{"query" => "q", "tags" => tags})
      assert %{"error" => error} = json_response(conn, 422)
      assert error =~ "tags"
    end
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

      note = note!(user, vault, "Health/Iron Panel.md", "Iron Panel")
      qdrant_result = %{"result" => [chunk(user, note, 0.95, "Ferritin levels.")]}

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query/batch", fn c ->
        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(QdrantStub.batch(c, qdrant_result)))
      end)

      conn = post(conn, "/api/search", %{query: "iron panel"})
      assert %{"results" => results} = json_response(conn, 200)
      assert length(results) == 1
      [hit] = results
      assert hit["score"] == QdrantStub.rrf(0)
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
        Engram.Notes.upsert_note(
          user,
          vault,
          %{
            "path" => "Health/Iron Panel.md",
            "content" => "# Iron Panel\n\nFerritin levels.",
            "mtime" => 1_000.0
          },
          actor: "api"
        )

      qdrant_result = %{"result" => [chunk(user, note, 0.95, "Ferritin levels.")]}

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query/batch", fn c ->
        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(QdrantStub.batch(c, qdrant_result)))
      end)

      conn = post(conn, "/api/search", %{query: "iron panel"})
      assert %{"results" => [hit]} = json_response(conn, 200)
      assert hit["id"] == note.id
      assert is_binary(hit["id"])
    end

    test "Search over-fetches a candidate pool so grouping can return the requested number of notes",
         %{conn: conn, bypass: bypass} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query/batch", fn c ->
        {:ok, body, c} = Plug.Conn.read_body(c)
        decoded = Jason.decode!(body)
        # Client requests 10 notes → Search asks Qdrant for max(10*4, 20)=40
        # candidates so collapse_to_notes has enough chunks to populate 10 notes.
        assert Enum.map(decoded["searches"], & &1["limit"]) == [40, 40]

        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result":[{"points":[]},{"points":[]}]}))
      end)

      # diversity: 0 disables MMR so the stub only sees the Search
      # grouping pool expansion (max(note_limit*4, 20)), not an MMR
      # candidate-pool expansion on top. This isolates the grouping mechanic.
      conn = post(conn, "/api/search", %{query: "test", limit: 10, diversity: "0"})
      assert %{"results" => []} = json_response(conn, 200)
    end

    test "web search requests hybrid mode", %{conn: conn, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query/batch", fn c ->
        {:ok, body, c} = Plug.Conn.read_body(c)
        assert Enum.map(Jason.decode!(body)["searches"], & &1["using"]) == ["dense", "keyword"]

        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result":[{"points":[]},{"points":[]}]}))
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

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query/batch", fn c ->
        {:ok, body, c} = Plug.Conn.read_body(c)
        assert Enum.map(Jason.decode!(body)["searches"], & &1["using"]) == ["dense", "keyword"]

        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result":[{"points":[]},{"points":[]}]}))
      end)

      conn = post(conn, ~p"/api/search", %{"query" => "ferritin", "mode" => "garbage"})
      assert json_response(conn, 200)["results"] == []
    end

    test "returns 422 when query is missing", %{conn: conn} do
      conn = post(conn, "/api/search", %{})
      assert json_response(conn, 422)
    end

    test "clamps note limit; Search over-fetches a candidate pool for grouping", %{
      conn: conn,
      bypass: bypass
    } do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query/batch", fn c ->
        {:ok, body, c} = Plug.Conn.read_body(c)
        decoded = Jason.decode!(body)
        # 999 notes → clamped to 50 → Search asks Qdrant for max(50*4, 20)=200 candidates.
        assert Enum.map(decoded["searches"], & &1["limit"]) == [200, 200]

        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result":[{"points":[]},{"points":[]}]}))
      end)

      # diversity: 0 isolates the controller clamp + Search pool sizing from
      # the MMR candidate-pool expansion that activates with the new 0.3 default.
      conn = post(conn, "/api/search", %{query: "test", limit: 999, diversity: "0"})
      assert json_response(conn, 200)
    end

    test "forwards type and date filters", %{conn: conn, bypass: bypass} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query/batch", fn c ->
        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result":[{"points":[]},{"points":[]}]}))
      end)

      conn =
        post(conn, ~p"/api/search", %{
          "query" => "x",
          "type" => "Playbook",
          "updated_after" => "2026-01-01T00:00:00Z"
        })

      assert json_response(conn, 200)
    end

    test "invalid date param is a 422", %{conn: conn} do
      conn = post(conn, ~p"/api/search", %{"query" => "x", "updated_after" => "not-a-date"})
      assert %{"error" => _} = json_response(conn, 422)
    end

    test "non-string date param is a 422", %{conn: conn} do
      conn = post(conn, ~p"/api/search", %{"query" => "x", "updated_after" => 123})
      assert %{"error" => _} = json_response(conn, 422)
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

      Bypass.expect(bypass, "POST", "/collections/engram_notes/points/query/batch", fn c ->
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

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query/batch", fn c ->
        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result":[{"points":[]},{"points":[]}]}))
      end)

      conn = post(conn, "/api/search", %{query: "nothing here"})
      assert %{"results" => []} = json_response(conn, 200)
    end

    test "Search groups repeated chunks from the same note into one result with match_count",
         %{conn: conn, bypass: bypass, user: user, vault: vault} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      iron = note!(user, vault, "Health/Iron Panel.md", "Iron Panel")
      vitd = note!(user, vault, "Health/Vitamin D.md", "Vitamin D")

      # Three top hits all point at the same note plus one different note —
      # Search.collapse_to_notes groups them by {vault_id, source_path} and
      # keeps the best chunk's score as the representative, with match_count.
      qdrant_result = %{
        "result" => [
          chunk(user, iron, 0.95, "Ferritin section.", 0),
          chunk(user, iron, 0.91, "TIBC section.", 1),
          chunk(user, iron, 0.88, "Notes on saturation.", 2),
          chunk(user, vitd, 0.80, "Levels by season.")
        ]
      }

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query/batch", fn c ->
        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(QdrantStub.batch(c, qdrant_result)))
      end)

      # diversity: 0 disables MMR so the stub doesn't need to supply vectors;
      # Search.collapse_to_notes runs without MMR reranking — isolates grouping.
      conn = post(conn, "/api/search", %{query: "iron", limit: 5, diversity: "0"})
      assert %{"results" => results} = json_response(conn, 200)

      # Two unique notes, sorted by best chunk score.
      assert length(results) == 2
      [iron, vitd] = results

      assert iron["path"] == "Health/Iron Panel.md"
      assert iron["match_count"] == 3
      assert iron["snippet"] == "Ferritin section."
      assert iron["score"] == QdrantStub.rrf(0)

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

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query/batch", fn c ->
        {:ok, body, c} = Plug.Conn.read_body(c)
        decoded = Jason.decode!(body)
        # diversity > 0 triggers the MMR path: Search requests dense vectors from
        # Qdrant so MMR can compare cosine similarity between candidates.
        # Qdrant so MMR can compare cosine similarity between candidates; they
        # come with the fused points' retrieve, not the legs.
        assert length(decoded["searches"]) == 2
        refute Enum.any?(decoded["searches"], &Map.has_key?(&1, "with_vector"))

        # Return a valid point with a dense vector so the MMR pipeline succeeds.
        points = [diverse_chunk(user, vault, "mmr-1", 0.9, [1.0, 0.0], "MMR result")]

        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(QdrantStub.batch(c, %{"result" => points})))
      end)

      conn = post(conn, ~p"/api/search", %{"query" => "hello", "diversity" => "0.5"})
      assert json_response(conn, 200)
      assert QdrantStub.last_retrieve(bypass)["with_vector"] == ["dense"]
    end

    test "out-of-range diversity=5 is clamped downstream — still returns 200", %{
      conn: conn,
      bypass: bypass
    } do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      # diversity=5 is parsed as a float and passed to Search; Search clamps it
      # to 1.0. The request is still valid and returns a 200 with results.
      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query/batch", fn c ->
        {:ok, _body, c} = Plug.Conn.read_body(c)

        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result":[{"points":[]},{"points":[]}]}))
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
      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query/batch", fn c ->
        {:ok, _body, c} = Plug.Conn.read_body(c)

        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result":[{"points":[]},{"points":[]}]}))
      end)

      conn = post(conn, ~p"/api/search", %{"query" => "hello", "diversity" => "not-a-float"})
      assert json_response(conn, 200)
    end

    test "honors the requested note limit — Search returns at most note_limit note-reps",
         %{conn: conn, bypass: bypass, user: user, vault: vault} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      result = %{
        "result" =>
          for i <- 1..10 do
            note = note!(user, vault, "F/Note #{i}.md", "Note #{i}")
            chunk(user, note, 1.0 - i * 0.01, "snippet #{i}")
          end
      }

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query/batch", fn c ->
        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(QdrantStub.batch(c, result)))
      end)

      # diversity: 0 disables MMR (which requires vectors in stub results);
      # Search groups chunks → note-reps and returns at most note_limit=3.
      conn = post(conn, "/api/search", %{query: "note", limit: 3, diversity: "0"})
      %{"results" => results} = json_response(conn, 200)
      assert length(results) == 3
    end

    # A merged chunk (several chunks in one point, under the per-note cap)
    # holds up to ~30 KB: the snippet is a window around the match.
    test "a merged hit's snippet is a window of at most 1,500 chars around the match", %{
      conn: conn,
      bypass: bypass,
      user: user,
      vault: vault
    } do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      result = %{
        "result" => [
          chunk(user, note!(user, vault, "Big.md", "Big"), 0.9, merged_text("quixotic"))
        ]
      }

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query/batch", fn c ->
        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(QdrantStub.batch(c, result)))
      end)

      conn = post(conn, "/api/search", %{query: "quixotic finale", diversity: 0})
      assert %{"results" => [hit]} = json_response(conn, 200)
      assert String.length(hit["snippet"]) <= 1_500
      assert hit["snippet"] =~ "quixotic finale"
    end
  end

  # ---------------------------------------------------------------------------
  # cross_vault=true searches PAST the request's X-Vault-ID, so VaultPlug's
  # single-vault check does not bound it. The only other gate is the Pro
  # `cross_vault_search` entitlement, which is billing, not scope — so before
  # this the emitted Qdrant query carried no vault filter at all and a
  # subset-restricted credential got hits from every vault the user owns.
  #
  # These assert on the EMITTED Qdrant filter, captured off the Bypass socket.
  # Asserting on the canned response body instead would pass whether or not the
  # filter is applied, which proves nothing.
  # ---------------------------------------------------------------------------
  describe "POST /search with cross_vault" do
    setup %{user: user, vault: vault} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})
      insert(:user_limit_override, user: user, key: "cross_vault_search", value: %{"v" => true})
      Engram.Billing.OverrideCache.evict(user.id)

      vault_b = insert(:vault, user: user)
      vault_c = insert(:vault, user: user)

      {:ok, raw_key, key_rec} = Engram.Accounts.create_api_key(user, "subset-key")

      # Permit A and B only — NOT C.
      Engram.Repo.insert_all("api_key_vaults", [
        %{api_key_id: Ecto.UUID.dump!(key_rec.id), vault_id: Ecto.UUID.dump!(vault.id)},
        %{api_key_id: Ecto.UUID.dump!(key_rec.id), vault_id: Ecto.UUID.dump!(vault_b.id)}
      ])

      restricted =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> put_req_header("x-vault-id", to_string(vault.id))

      %{restricted: restricted, vault_b: vault_b, vault_c: vault_c}
    end

    test "a subset-restricted key searches exactly its subset, never the whole account", %{
      restricted: conn,
      bypass: bypass,
      user: user,
      vault: vault,
      vault_b: vault_b,
      vault_c: vault_c
    } do
      stub(Engram.MockEmbedder, :embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)
      test_pid = self()

      points = [
        chunk(user, note!(user, vault, "A/a.md", "A"), 0.9, "findme"),
        chunk(user, note!(user, vault_b, "B/b.md", "B"), 0.8, "findme")
      ]

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query/batch", fn c ->
        {:ok, raw, c} = Plug.Conn.read_body(c)
        send(test_pid, {:qdrant_body, Jason.decode!(raw)})

        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(QdrantStub.batch(c, %{"result" => points})))
      end)

      conn = post(conn, "/api/search", %{query: "findme", cross_vault: true})
      assert %{"results" => results} = json_response(conn, 200)
      assert length(results) == 2

      # The safety property: every leg of the emitted query carries an any-match
      # filter over exactly the permitted set. (Default mode is :hybrid, so the
      # filter rides each `searches` leg; `[body]` covers the dense shape.)
      assert_received {:qdrant_body, body}
      legs = body["searches"] || [body]
      assert legs != []

      for leg <- legs do
        clause = Enum.find(legacy_view(leg["filter"]["must"]), &(&1["key"] == "vault_id"))
        assert %{"match" => %{"any" => ids}} = clause
        assert Enum.sort(ids) == Enum.sort([to_string(vault.id), to_string(vault_b.id)])
        refute to_string(vault_c.id) in ids
      end
    end

    # `?cross_vault=false` arrives as the STRING "false", which is truthy in
    # Elixir — read raw it turned an explicit opt-OUT into an opt-IN (and then
    # 403'd the caller on the Pro gate for a feature they were opting out of).
    # The emitted filter is the proof: a single-vault search filters on the ONE
    # request vault (`match.value`), never the any-match set a cross-vault
    # search emits.
    test "cross_vault=false stays single-vault instead of reading as truthy", %{
      restricted: conn,
      bypass: bypass,
      vault: vault,
      vault_b: vault_b
    } do
      stub(Engram.MockEmbedder, :embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query/batch", fn c ->
        {:ok, raw, c} = Plug.Conn.read_body(c)
        send(test_pid, {:qdrant_body, Jason.decode!(raw)})

        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "result" => [%{"id" => Ecto.UUID.generate(), "score" => 0.9}]
          })
        )
      end)

      conn = post(conn, "/api/search", %{query: "findme", cross_vault: "false"})
      assert %{"results" => _} = json_response(conn, 200)

      assert_received {:qdrant_body, body}

      for leg <- body["searches"] || [body] do
        clause = Enum.find(legacy_view(leg["filter"]["must"]), &(&1["key"] == "vault_id"))
        assert clause["match"] == %{"value" => to_string(vault.id)}
        refute to_string(vault_b.id) in List.wrap(clause["match"]["any"])
      end
    end

    # Narrowing the SEARCH and then resolving ids outside the narrowing defeats
    # the point: with `vault: nil` the id lookup matched `path_hmac` across every
    # vault the user owns, so a path present in both a permitted and a
    # non-permitted vault could return the out-of-scope note's UUID.
    test "the id comes from the result's own vault, not a same-path note elsewhere", %{
      restricted: conn,
      bypass: bypass,
      user: user,
      vault: vault,
      vault_c: vault_c
    } do
      stub(Engram.MockEmbedder, :embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      # Same path in both vaults. C is inserted LAST on purpose: the old
      # vault-blind reduce kept whichever row came back last, so this ordering
      # is what makes the bug observable rather than a coin flip.
      permitted = Engram.Fixtures.insert_note!(user, vault, %{"path" => "Inbox.md"})
      out_of_scope = Engram.Fixtures.insert_note!(user, vault_c, %{"path" => "Inbox.md"})

      result = %{"result" => [chunk(user, permitted, 0.9, "findme")]}

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query/batch", fn c ->
        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(QdrantStub.batch(c, result)))
      end)

      conn = post(conn, "/api/search", %{query: "findme", cross_vault: true})
      assert %{"results" => [hit]} = json_response(conn, 200)

      assert hit["id"] == permitted.id
      refute hit["id"] == out_of_scope.id
    end

    # The over-block is as much a bug as the leak: an unrestricted credential is
    # entitled to search everything, so it must emit NO vault filter.
    test "an unrestricted key still searches every vault", %{conn: conn, bypass: bypass} do
      stub(Engram.MockEmbedder, :embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query/batch", fn c ->
        {:ok, raw, c} = Plug.Conn.read_body(c)
        send(test_pid, {:qdrant_body, Jason.decode!(raw)})

        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "result" => [%{"id" => Ecto.UUID.generate(), "score" => 0.9}]
          })
        )
      end)

      conn = post(conn, "/api/search", %{query: "findme", cross_vault: true})
      assert %{"results" => _} = json_response(conn, 200)

      assert_received {:qdrant_body, body}

      for leg <- body["searches"] || [body] do
        refute Enum.any?(legacy_view(leg["filter"]["must"]) || [], &(&1["key"] == "vault_id"))
      end
    end
  end

  defp note!(user, vault, path, title),
    do: Engram.Fixtures.insert_note!(user, vault, %{path: path, title: title})

  # A hit on `note` at chunk position `pos`: its chunk row holds the text,
  # the note row the path, title and vault.
  defp chunk(user, note, score, text, pos \\ 0) do
    id =
      Engram.Fixtures.insert_chunk!(user, note, Ecto.UUID.generate(), position: pos, text: text)

    %{"id" => id, "score" => score}
  end

  # ~30 KB of filler paragraphs with `word` in one near the end.
  defp merged_text(word) do
    Enum.map_join(1..600, "\n\n", fn
      550 -> "Paragraph 550 holds the #{word} finale."
      i -> "Paragraph #{i} of ordinary filler text."
    end)
  end

  # A payload point with a dense vector so the MMR path can run
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
