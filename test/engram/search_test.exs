defmodule Engram.SearchTest do
  use Engram.DataCase, async: false

  import Bitwise, only: [bxor: 2]
  import Mox

  alias Engram.Search

  setup :verify_on_exit!

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    {:ok, user} = insert(:user) |> Engram.Crypto.ensure_user_dek()
    vault = insert(:vault, user: user)
    %{bypass: bypass, user: user, vault: vault}
  end

  describe "search/4" do
    test "returns results from Qdrant", %{bypass: bypass, user: user, vault: vault} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn ["iron panel"], _opts ->
        {:ok, [List.duplicate(0.1, 3)]}
      end)

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

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(qdrant_result))
      end)

      assert {:ok, results} = Search.search(user, vault, "iron panel")
      assert length(results) == 1
      assert hd(results).score == 0.95
      assert hd(results).source_path == "Health/Iron Panel.md"
      assert hd(results).text == "Ferritin levels."
    end

    test "#590: rehydrates source_path/tags from PG when payload omits them",
         %{bypass: bypass, user: user, vault: vault} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _texts, _opts -> {:ok, [List.duplicate(0.1, 3)]} end)

      # A real note carries the canonical path/tags; the Qdrant payload no
      # longer does (#590). The chunk row maps the point id back to the note.
      {:ok, note} =
        Engram.Notes.upsert_note(user, vault, %{
          "path" => "Health/iron.md",
          "content" => "---\ntags: [labs]\n---\n# Iron\n\nFerritin levels.",
          "mtime" => 1_000.0
        })

      point_id = Ecto.UUID.generate()

      {:ok, _} =
        Engram.Repo.with_tenant(user.id, fn ->
          %Engram.Notes.Chunk{}
          |> Engram.Notes.Chunk.changeset(%{
            note_id: note.id,
            user_id: user.id,
            vault_id: vault.id,
            position: 0,
            char_start: 0,
            char_end: 10,
            qdrant_point_id: point_id
          })
          |> Engram.Repo.insert!()
        end)

      {:ok, enc} =
        Engram.Crypto.encrypt_qdrant_payload(
          %{text: "Ferritin levels.", title: "Iron", heading_path: "Iron"},
          user,
          "engram_notes",
          point_id
        )

      qdrant_result = %{
        "result" => [
          %{
            "id" => point_id,
            "score" => 0.9,
            "payload" => %{
              "text" => enc.text,
              "title" => enc.title,
              "heading_path" => enc.heading_path,
              "text_nonce" => enc.text_nonce,
              "title_nonce" => enc.title_nonce,
              "heading_path_nonce" => enc.heading_path_nonce,
              "aad_version" => enc.aad_version,
              "user_id" => to_string(user.id),
              "vault_id" => to_string(vault.id)
              # NB: no "source_path", no "tags" — that's the #590 fix.
            }
          }
        ]
      }

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(qdrant_result))
      end)

      assert {:ok, [result]} = Search.search(user, vault, "iron")
      assert result.source_path == "Health/iron.md"
      assert result.tags == ["labs"]
    end

    test "includes vault_id filter in Qdrant request", %{bypass: bypass, user: user, vault: vault} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        conditions = decoded["filter"]["must"]
        keys = Enum.map(conditions, & &1["key"])
        assert "vault_id" in keys

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": []}))
      end)

      assert {:ok, []} = Search.search(user, vault, "query")
    end

    test "translates :folder opt into folder_hmac filter (Phase B.2.3)",
         %{bypass: bypass, user: user, vault: vault} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
      expected_hmac = Base.encode64(Engram.Crypto.hmac_field(filter_key, "Health"))

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        conditions = decoded["filter"]["must"]
        keys = Enum.map(conditions, & &1["key"])

        # Plaintext folder filter is gone; HMAC filter takes its place.
        refute "folder" in keys
        assert "folder_hmac" in keys

        folder_cond = Enum.find(conditions, &(&1["key"] == "folder_hmac"))
        assert folder_cond["match"]["value"] == expected_hmac

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": []}))
      end)

      assert {:ok, []} = Search.search(user, vault, "query", folder: "Health")
    end

    test "translates :tags opt into tags_hmac filter (Phase B.2.3)",
         %{bypass: bypass, user: user, vault: vault} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)

      expected_hmacs =
        ["health", "labs"]
        |> Enum.map(&Base.encode64(Engram.Crypto.hmac_field(filter_key, &1)))

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        conditions = decoded["filter"]["must"]
        keys = Enum.map(conditions, & &1["key"])

        refute "tags" in keys
        assert "tags_hmac" in keys

        tags_cond = Enum.find(conditions, &(&1["key"] == "tags_hmac"))
        assert Enum.sort(tags_cond["match"]["any"]) == Enum.sort(expected_hmacs)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": []}))
      end)

      assert {:ok, []} = Search.search(user, vault, "query", tags: ["health", "labs"])
    end

    test "user without DEK returns empty result for filtered search instead of crashing",
         %{bypass: bypass} do
      # Brand-new user — no notes upserted, no DEK provisioned. Mirrors the
      # multi-tenant edge case fixed for list_folders in B.2.2.
      user_no_dek = insert(:user)
      vault = insert(:vault, user: user_no_dek)

      Bypass.stub(bypass, "POST", "/collections/engram_notes/points/query", fn _ ->
        flunk("Qdrant must not be queried when caller has no DEK and supplied folder/tags")
      end)

      assert {:ok, []} = Search.search(user_no_dek, vault, "query", folder: "Health")
      assert {:ok, []} = Search.search(user_no_dek, vault, "query", tags: ["x"])
    end

    test "returns error when embedder fails", %{user: user, vault: vault} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _, _ -> {:error, :unavailable} end)

      assert {:error, _} = Search.search(user, vault, "iron panel")
    end

    test "fetches 4x candidates when reranker is configured", %{
      bypass: bypass,
      user: user,
      vault: vault
    } do
      # Configure Jina reranker via behaviour
      jina_bypass = Bypass.open()
      Application.put_env(:engram, :reranker, Engram.Rerankers.Jina)
      Application.put_env(:engram, :jina_url, "http://localhost:#{jina_bypass.port}")

      # Grant reranker_enabled — pricing-v2 §G now gates rerank per-plan.
      insert(:user_limit_override,
        user: user,
        key: "reranker_enabled",
        value: %{"v" => true}
      )

      on_exit(fn ->
        Application.put_env(:engram, :reranker, Engram.Rerankers.None)
        Application.delete_env(:engram, :jina_url)
      end)

      Engram.MockEmbedder
      |> expect(:embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        # With limit=2, should request 4x = 8, but min 20
        assert decoded["limit"] == 20

        results =
          for i <- 0..3 do
            qid = "uuid-#{i}"

            {:ok, enc} =
              Engram.Crypto.encrypt_qdrant_payload(
                %{text: "Result #{i}", title: "Note #{i}", heading_path: "Section"},
                user,
                "engram_notes",
                qid
              )

            %{
              "id" => qid,
              "score" => 0.9 - i * 0.1,
              "payload" => %{
                "text" => enc.text,
                "title" => enc.title,
                "heading_path" => enc.heading_path,
                "text_nonce" => enc.text_nonce,
                "title_nonce" => enc.title_nonce,
                "heading_path_nonce" => enc.heading_path_nonce,
                "aad_version" => enc.aad_version,
                "source_path" => "test/note#{i}.md",
                "tags" => [],
                "user_id" => to_string(user.id),
                "vault_id" => to_string(vault.id)
              }
            }
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"result" => results}))
      end)

      Bypass.expect_once(jina_bypass, "POST", "/rerank", fn conn ->
        resp = %{
          "results" => [
            %{"index" => 3, "relevance_score" => 0.99},
            %{"index" => 0, "relevance_score" => 0.80},
            %{"index" => 1, "relevance_score" => 0.50},
            %{"index" => 2, "relevance_score" => 0.30}
          ]
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end)

      assert {:ok, results} = Search.search(user, vault, "test query", limit: 2)
      assert length(results) == 2
      # Result 3 should be first (highest reranker score)
      assert hd(results).source_path == "test/note3.md"
    end

    test "skips rerank for Free user even when reranker is globally configured (§G)",
         %{bypass: bypass, user: user, vault: vault} do
      # Globally configure a Jina reranker — but DO NOT grant the user the
      # reranker_enabled feature flag. Pricing-v2 §G demands per-plan gating
      # on the server, not just client-side opt-in.
      jina_bypass = Bypass.open()
      Application.put_env(:engram, :reranker, Engram.Rerankers.Jina)
      Application.put_env(:engram, :jina_url, "http://localhost:#{jina_bypass.port}")

      on_exit(fn ->
        Application.put_env(:engram, :reranker, Engram.Rerankers.None)
        Application.delete_env(:engram, :jina_url)
      end)

      Engram.MockEmbedder
      |> expect(:embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      # Free user → reranker_enabled=false → fetch_limit should equal the
      # requested limit (2), NOT 4× / @min_candidates. Verifies that Qdrant
      # isn't being asked for the rerank-sized candidate set.
      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["limit"] == 2

        qid = "uuid-free"

        {:ok, enc} =
          Engram.Crypto.encrypt_qdrant_payload(
            %{text: "Plain", title: "Plain", heading_path: "Plain"},
            user,
            "engram_notes",
            qid
          )

        result = %{
          "id" => qid,
          "score" => 0.5,
          "payload" => %{
            "text" => enc.text,
            "title" => enc.title,
            "heading_path" => enc.heading_path,
            "text_nonce" => enc.text_nonce,
            "title_nonce" => enc.title_nonce,
            "heading_path_nonce" => enc.heading_path_nonce,
            "aad_version" => enc.aad_version,
            "source_path" => "test/free.md",
            "tags" => [],
            "user_id" => to_string(user.id),
            "vault_id" => to_string(vault.id)
          }
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"result" => [result]}))
      end)

      # Jina MUST NOT be called for a Free user — Bypass.expect_once would
      # fail if the bypass receives a request; here we use Bypass.stub with
      # no expectation, and the test inherently fails Mox/Bypass if Jina is
      # hit (jina_bypass has no expect set up).
      assert {:ok, [result]} = Search.search(user, vault, "test query", limit: 2)
      assert result.source_path == "test/free.md"
    end

    test "uses query embed model when configured", %{bypass: bypass, user: user, vault: vault} do
      Application.put_env(:engram, :query_embed_model, "voyage-4-lite")
      on_exit(fn -> Application.delete_env(:engram, :query_embed_model) end)

      Engram.MockEmbedder
      |> expect(:embed_texts, fn ["test query"], opts ->
        assert opts[:model] == "voyage-4-lite"
        assert opts[:purpose] == :query
        {:ok, [List.duplicate(0.1, 3)]}
      end)

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": []}))
      end)

      assert {:ok, []} = Search.search(user, vault, "test query")
    end

    test "uses default embed when query model not configured", %{
      bypass: bypass,
      user: user,
      vault: vault
    } do
      Application.delete_env(:engram, :query_embed_model)

      Engram.MockEmbedder
      |> expect(:embed_texts, fn ["test query"], opts ->
        assert opts[:purpose] == :query
        {:ok, [List.duplicate(0.1, 3)]}
      end)

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": []}))
      end)

      assert {:ok, []} = Search.search(user, vault, "test query")
    end

    test "returns empty list when Qdrant returns no results", %{
      bypass: bypass,
      user: user,
      vault: vault
    } do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": []}))
      end)

      assert {:ok, []} = Search.search(user, vault, "nothing")
    end

    test "cross-vault search returns error when feature disabled (free plan)", %{
      user: user,
      vault: vault
    } do
      # Free plan user has no plan_id; @default_limits has cross_vault_search: false
      assert user.plan_id == nil

      assert {:error, :feature_not_available} =
               Search.search(user, vault, "query", cross_vault: true)
    end

    test "cross-vault search proceeds past billing gate when feature enabled (pro plan)", %{
      bypass: bypass,
      vault: vault
    } do
      plan = insert(:plan, limits: %{"cross_vault_search" => true})
      pro_user = insert(:user, plan_id: plan.id)

      Engram.MockEmbedder
      |> expect(:embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": []}))
      end)

      result = Search.search(pro_user, vault, "query", cross_vault: true)
      refute result == {:error, :feature_not_available}
    end

    test "default (non-cross-vault) search skips billing gate for free plan user", %{
      bypass: bypass,
      user: user,
      vault: vault
    } do
      # Free plan user — no cross_vault opt — should never hit the billing check
      Engram.MockEmbedder
      |> expect(:embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": []}))
      end)

      result = Search.search(user, vault, "query")
      refute result == {:error, :feature_not_available}
    end

    test "folder marker rows do not appear in search results", %{
      bypass: bypass,
      user: user,
      vault: vault
    } do
      # Defense-in-depth: markers carry no content and no embedding (Task 10
      # filters them at the EmbedNote enqueue boundary), so they can never
      # legitimately reach Qdrant. This test pins the contract — create a
      # marker AND a real note in the same folder, search, assert that only
      # the real note's source_path can come back. Qdrant is mocked to return
      # exactly what the embedding pipeline would have indexed (one row for
      # the real note, none for the marker).
      {:ok, _marker} = Engram.Notes.create_folder_marker(user, vault, "Findable")

      {:ok, _note} =
        Engram.Notes.upsert_note(user, vault, %{
          "path" => "Findable/Real.md",
          "content" => "Findable target body",
          "mtime" => 1.0
        })

      Engram.MockEmbedder
      |> expect(:embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      {:ok, enc} =
        Engram.Crypto.encrypt_qdrant_payload(
          %{text: "Findable target body", title: "Real", heading_path: "Real"},
          user,
          "engram_notes",
          "uuid-real"
        )

      qdrant_result = %{
        "result" => [
          %{
            "id" => "uuid-real",
            "score" => 0.9,
            "payload" => %{
              "text" => enc.text,
              "title" => enc.title,
              "heading_path" => enc.heading_path,
              "text_nonce" => enc.text_nonce,
              "title_nonce" => enc.title_nonce,
              "heading_path_nonce" => enc.heading_path_nonce,
              "aad_version" => enc.aad_version,
              "source_path" => "Findable/Real.md",
              "tags" => [],
              "user_id" => to_string(user.id),
              "vault_id" => to_string(vault.id)
            }
          }
        ]
      }

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(qdrant_result))
      end)

      assert {:ok, results} = Search.search(user, vault, "Findable")
      assert length(results) == 1

      Enum.each(results, fn r ->
        # Markers have no path — if one ever leaked into results, source_path
        # would be nil/empty. Pin that this never happens.
        assert r.source_path not in [nil, ""]
        refute r.source_path == "Findable"
      end)
    end
  end

  describe "search/4 with encrypted vaults" do
    setup do
      Engram.Crypto.DekCache.invalidate_all()
      user = insert(:user)
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      enc_vault = insert(:vault, user: user)

      {:ok, user: user, enc_vault: enc_vault}
    end

    test "decrypts encrypted-vault candidates before returning results", %{
      bypass: bypass,
      user: user,
      enc_vault: vault
    } do
      {:ok, enc} =
        Engram.Crypto.encrypt_qdrant_payload(
          %{text: "alpha body", title: "Alpha", heading_path: "root"},
          user,
          "engram_notes",
          "qid-a"
        )

      _ = vault

      Engram.MockEmbedder
      |> expect(:embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      qdrant_result = %{
        "result" => [
          %{
            "id" => "qid-a",
            "score" => 0.95,
            "payload" => %{
              "text" => enc.text,
              "title" => enc.title,
              "heading_path" => enc.heading_path,
              "text_nonce" => enc.text_nonce,
              "title_nonce" => enc.title_nonce,
              "heading_path_nonce" => enc.heading_path_nonce,
              "aad_version" => enc.aad_version,
              "source_path" => "a.md",
              "tags" => [],
              "user_id" => to_string(user.id),
              "vault_id" => to_string(vault.id)
            }
          }
        ]
      }

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(qdrant_result))
      end)

      assert {:ok, [result]} = Search.search(user, vault, "query")
      assert result.text == "alpha body"
      assert result.title == "Alpha"
      assert result.heading_path == "root"
      refute Map.has_key?(result, :text_nonce)
    end

    test "returns {:error, :decrypt_failed} when ALL encrypted candidates fail decrypt", %{
      bypass: bypass,
      user: user,
      enc_vault: vault
    } do
      {:ok, enc} =
        Engram.Crypto.encrypt_qdrant_payload(
          %{text: "beta body", title: "Beta", heading_path: "root"},
          user,
          "engram_notes",
          "qid-b"
        )

      _ = vault

      # Tamper: flip one bit of the decoded ciphertext.
      <<first, rest::binary>> = Base.decode64!(enc.text)
      tampered_text = Base.encode64(<<bxor(first, 1), rest::binary>>)

      Engram.MockEmbedder
      |> expect(:embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      qdrant_result = %{
        "result" => [
          %{
            "id" => "qid-b",
            "score" => 0.9,
            "payload" => %{
              "text" => tampered_text,
              "title" => enc.title,
              "heading_path" => enc.heading_path,
              "text_nonce" => enc.text_nonce,
              "title_nonce" => enc.title_nonce,
              "heading_path_nonce" => enc.heading_path_nonce,
              "aad_version" => enc.aad_version,
              "source_path" => "b.md",
              "tags" => [],
              "user_id" => to_string(user.id),
              "vault_id" => to_string(vault.id)
            }
          }
        ]
      }

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(qdrant_result))
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :decrypt_failed} = Search.search(user, vault, "query")
        end)

      assert log =~ "decrypt"
    end
  end
end
