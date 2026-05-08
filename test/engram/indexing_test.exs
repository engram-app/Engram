defmodule Engram.IndexingTest do
  use Engram.DataCase, async: false

  import Mox

  alias Engram.Indexing
  alias Engram.Notes

  # Mox requires that expectations are verified after each test
  setup :verify_on_exit!

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    user = insert(:user)
    vault = insert(:vault, user: user)

    {:ok, note} =
      Notes.upsert_note(user, vault, %{
        "path" => "Health/Iron Panel.md",
        "content" => "---\ntags: [health]\n---\n# Iron Panel\n\nFerritin levels.",
        "mtime" => 1_000.0
      })

    %{bypass: bypass, user: user, vault: vault, note: note}
  end

  # ---------------------------------------------------------------------------
  # index_note/2
  # ---------------------------------------------------------------------------

  describe "index_note/2" do
    test "embeds chunks and upserts to Qdrant + Postgres", %{
      bypass: bypass,
      note: note,
      vault: vault
    } do
      # Mock embedder returns one 3-dim vector per chunk
      Engram.MockEmbedder
      |> expect(:embed_texts, fn texts ->
        vectors = Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)
        {:ok, vectors}
      end)

      # Qdrant: ensure_collection + delete + upsert
      Bypass.expect(bypass, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": true}))
      end)

      assert {:ok, chunk_count} = Indexing.index_note(note, vault)
      assert chunk_count > 0

      # Postgres chunks rows should be created (skip_tenant_check: tests are trusted)
      import Ecto.Query
      chunks = Engram.Repo.all(from(c in Engram.Notes.Chunk), skip_tenant_check: true)
      assert length(chunks) == chunk_count
    end

    test "uses doc embed model when configured", %{bypass: bypass, note: note, vault: vault} do
      Application.put_env(:engram, :doc_embed_model, "voyage-4-large")
      on_exit(fn -> Application.delete_env(:engram, :doc_embed_model) end)

      Engram.MockEmbedder
      |> expect(:embed_texts, fn texts, [model: "voyage-4-large"] ->
        {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
      end)

      Bypass.expect(bypass, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": true}))
      end)

      assert {:ok, chunk_count} = Indexing.index_note(note, vault)
      assert chunk_count > 0
    end

    test "skips embedding for empty content", %{vault: vault} do
      note = %Engram.Notes.Note{
        id: 999,
        path: "Test/Empty.md",
        content: "",
        user_id: 1,
        vault_id: 1,
        title: "Empty",
        folder: "Test",
        tags: [],
        version: 1,
        content_hash: ""
      }

      assert {:ok, 0} = Indexing.index_note(note, vault)
    end
  end

  # ---------------------------------------------------------------------------
  # index_note/2 with encrypted vault
  # ---------------------------------------------------------------------------

  describe "index_note/2 with encrypted vault" do
    test "encrypts text/title/heading_path in Qdrant payload", %{bypass: bypass, user: user} do
      Engram.Crypto.DekCache.invalidate_all()
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      vault = insert(:vault, user: user)

      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "secret/note.md",
          "content" => "# Secret\n\nClassified body.",
          "mtime" => 1_000.0
        })

      # Re-decrypt since upsert_note encrypted the note content (Phase 3 behaviour).
      {:ok, note} = Engram.Crypto.maybe_decrypt_note_fields(note, user)

      Engram.MockEmbedder
      |> expect(:embed_texts, fn texts ->
        {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
      end)

      test_pid = self()

      Bypass.expect(bypass, fn conn ->
        if String.contains?(conn.request_path, "/points") and conn.method == "PUT" do
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:upsert_body, Jason.decode!(body)})
          Plug.Conn.send_resp(conn, 200, ~s({"result": true}))
        else
          Plug.Conn.send_resp(conn, 200, ~s({"result": true}))
        end
      end)

      assert {:ok, _count} = Indexing.index_note(note, vault)

      assert_received {:upsert_body, body}
      points = body["points"]
      assert length(points) > 0

      Enum.each(points, fn p ->
        payload = p["payload"]
        assert Map.has_key?(payload, "text_nonce")
        assert Map.has_key?(payload, "title_nonce")
        assert Map.has_key?(payload, "heading_path_nonce")
        # text should be base64-encoded ciphertext, not the plaintext
        refute payload["text"] == "Classified body."
        refute payload["text"] =~ "Classified"
        assert is_binary(payload["text_nonce"])
        # base64 round-trip should succeed
        assert {:ok, _} = Base.decode64(payload["text"])
        assert {:ok, _} = Base.decode64(payload["text_nonce"])
      end)
    end

    test "Phase B: payload includes base64-encoded path/folder/tags hmacs",
         %{bypass: bypass, user: user} do
      Engram.Crypto.DekCache.invalidate_all()
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      vault = insert(:vault, user: user)

      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "Health/iron.md",
          "content" => "---\ntags: [labs, ferritin]\n---\n# Iron",
          "mtime" => 1_000.0
        })

      Engram.MockEmbedder
      |> expect(:embed_texts, fn texts ->
        {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
      end)

      test_pid = self()

      Bypass.expect(bypass, fn conn ->
        if String.contains?(conn.request_path, "/points") and conn.method == "PUT" do
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:upsert_body, Jason.decode!(body)})
          Plug.Conn.send_resp(conn, 200, ~s({"result": true}))
        else
          Plug.Conn.send_resp(conn, 200, ~s({"result": true}))
        end
      end)

      assert {:ok, _} = Indexing.index_note(note, vault)
      assert_received {:upsert_body, body}

      {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
      expected_path_hmac = Base.encode64(Engram.Crypto.hmac_field(filter_key, "Health/iron.md"))
      expected_folder_hmac = Base.encode64(Engram.Crypto.hmac_field(filter_key, "Health"))
      expected_labs_hmac = Base.encode64(Engram.Crypto.hmac_field(filter_key, "labs"))
      expected_ferritin_hmac = Base.encode64(Engram.Crypto.hmac_field(filter_key, "ferritin"))

      Enum.each(body["points"], fn p ->
        payload = p["payload"]
        assert payload["path_hmac"] == expected_path_hmac
        assert payload["folder_hmac"] == expected_folder_hmac
        assert is_list(payload["tags_hmac"])
        assert expected_labs_hmac in payload["tags_hmac"]
        assert expected_ferritin_hmac in payload["tags_hmac"]
      end)
    end

    @tag capture_log: true
    test "emits encrypt_failed telemetry when DEK missing on encrypted vault", %{bypass: bypass} do
      # User has NO DEK provisioned — encrypted vault → maybe_encrypt_qdrant_payload
      # returns {:error, :no_dek} → reduce_while halts → telemetry fires.
      user = insert(:user)
      vault = insert(:vault, user: user)

      {:ok, note} =
        Engram.Notes.upsert_note(user, vault, %{
          "path" => "no-dek/note.md",
          "content" => "body",
          "mtime" => 1_000.0
        })

      # Reload user — upsert_note auto-provisioned the DEK via
      # maybe_encrypt_note_fields, but our local user struct is stale.
      user = Engram.Repo.get!(Engram.Accounts.User, user.id, skip_tenant_check: true)

      # Decrypt note while DEK still exists (simulates worker's decrypt step).
      {:ok, plaintext_note} = Engram.Crypto.maybe_decrypt_note_fields(note, user)

      # Now clear the DEK so that Indexing's re-encrypt attempt fails.
      # upsert_note auto-provisioned via maybe_encrypt_note_fields; simulate the
      # "DEK missing at index time" scenario that emits telemetry.
      import Ecto.Query

      Engram.Repo.update_all(
        from(u in Engram.Accounts.User, where: u.id == ^user.id),
        [set: [encrypted_dek: nil]],
        skip_tenant_check: true
      )

      Engram.Crypto.DekCache.invalidate(user.id)
      user_cleared = Engram.Repo.get!(Engram.Accounts.User, user.id, skip_tenant_check: true)
      _ = user_cleared

      Engram.MockEmbedder
      |> expect(:embed_texts, fn texts ->
        {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
      end)

      Bypass.expect(bypass, fn conn ->
        Plug.Conn.send_resp(conn, 200, ~s({"result": true}))
      end)

      handler_id = {__MODULE__, :encrypt_failed_handler, System.unique_integer()}
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:engram, :indexing, :encrypt_failed],
        fn _event, measurements, meta, _ ->
          send(test_pid, {:encrypt_failed_fired, measurements, meta})
        end,
        nil
      )

      try do
        assert {:error, :no_dek} = Indexing.index_note(plaintext_note, vault)

        assert_received {:encrypt_failed_fired, %{count: 1}, meta}
        assert meta.user_id == user.id
        assert meta.vault_id == vault.id
        assert meta.note_id == plaintext_note.id
      after
        :telemetry.detach(handler_id)
      end
    end

    test "encryption failure preserves prior chunks (no partial-failure drift)", %{bypass: bypass} do
      # Index once successfully, then re-index with a missing DEK. The old
      # chunks must survive because encrypt-first aborts before any Postgres
      # mutation.
      user = insert(:user)
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      vault = insert(:vault, user: user)

      {:ok, note} =
        Engram.Notes.upsert_note(user, vault, %{
          "path" => "atomic/note.md",
          "content" => "# Title\n\nFirst body.",
          "mtime" => 1_000.0
        })

      {:ok, plaintext_note} = Engram.Crypto.maybe_decrypt_note_fields(note, user)

      Engram.MockEmbedder
      |> expect(:embed_texts, 2, fn texts ->
        {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
      end)

      Bypass.expect(bypass, fn conn ->
        Plug.Conn.send_resp(conn, 200, ~s({"result": true}))
      end)

      assert {:ok, initial_count} = Indexing.index_note(plaintext_note, vault)
      assert initial_count > 0

      import Ecto.Query

      original_ids =
        Engram.Repo.all(
          from(c in Engram.Notes.Chunk, where: c.note_id == ^plaintext_note.id, select: c.id),
          skip_tenant_check: true
        )
        |> Enum.sort()

      assert length(original_ids) == initial_count

      # Clear the DEK so the next index_note/2 fails at encrypt.
      Engram.Repo.update_all(
        from(u in Engram.Accounts.User, where: u.id == ^user.id),
        [set: [encrypted_dek: nil]],
        skip_tenant_check: true
      )

      Engram.Crypto.DekCache.invalidate(user.id)

      assert {:error, :no_dek} = Indexing.index_note(plaintext_note, vault)

      # Old chunks must still be there — encrypt-first means no Postgres mutation
      # happens when encryption fails.
      surviving_ids =
        Engram.Repo.all(
          from(c in Engram.Notes.Chunk, where: c.note_id == ^plaintext_note.id, select: c.id),
          skip_tenant_check: true
        )
        |> Enum.sort()

      assert surviving_ids == original_ids,
             "expected prior chunks to survive failed re-index; got #{inspect(surviving_ids)} vs #{inspect(original_ids)}"
    end
  end

  # ---------------------------------------------------------------------------
  # commit_index/1 — Qdrant delete filter (T3.2 / T3 audit C1)
  # ---------------------------------------------------------------------------

  describe "commit_index Qdrant delete filter" do
    @tag capture_log: true
    test "filters by base64 path_hmac, not plaintext path (T3.2 / T3-audit C1)",
         %{bypass: bypass, user: user} do
      # Regression: T3.2 changed Qdrant.delete_by_note/4 to match against the
      # `path_hmac` payload key, but commit_index/1 was missed in the sweep
      # and kept passing plaintext `note.path`. Result: zero points deleted on
      # every re-index → orphaned ghost chunks accumulate per edit.
      Engram.Crypto.DekCache.invalidate_all()
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      vault = insert(:vault, user: user)

      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "ghosts/note.md",
          "content" => "# Ghosts\n\nBody.",
          "mtime" => 1_000.0
        })

      {:ok, decrypted} = Engram.Crypto.maybe_decrypt_note_fields(note, user)

      Engram.MockEmbedder
      |> expect(:embed_texts, fn texts ->
        {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
      end)

      test_pid = self()

      Bypass.expect(bypass, fn conn ->
        if String.ends_with?(conn.request_path, "/points/delete") do
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:delete_filter, Jason.decode!(body)})
          Plug.Conn.send_resp(conn, 200, ~s({"result": {"status": "ok"}}))
        else
          Plug.Conn.send_resp(conn, 200, ~s({"result": true}))
        end
      end)

      assert {:ok, _} = Indexing.index_note(decrypted, vault)

      assert_received {:delete_filter, body}
      must = body["filter"]["must"]

      path_hmac_clause = Enum.find(must, fn c -> c["key"] == "path_hmac" end)
      assert path_hmac_clause, "expected delete filter to key on path_hmac, got: #{inspect(must)}"
      assert path_hmac_clause["match"]["value"] == Base.encode64(note.path_hmac)

      refute Enum.any?(must, fn c -> c["key"] == "source_path" end),
             "delete filter must not key on plaintext source_path post-T3.2"

      refute Enum.any?(must, fn c ->
               v = get_in(c, ["match", "value"])
               is_binary(v) and v == note.path
             end),
             "delete filter must not contain plaintext path #{inspect(note.path)}"
    end
  end

  # ---------------------------------------------------------------------------
  # delete_note_index/1
  # ---------------------------------------------------------------------------

  describe "delete_note_index/1" do
    test "deletes chunks from Postgres and Qdrant", %{bypass: bypass, note: note, vault: vault} do
      # First index it
      Engram.MockEmbedder
      |> expect(:embed_texts, fn texts ->
        {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
      end)

      Bypass.expect(bypass, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": true}))
      end)

      {:ok, _} = Indexing.index_note(note, vault)

      # Now delete — Qdrant should get a delete request
      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/delete", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": {"status": "ok"}}))
      end)

      assert :ok = Indexing.delete_note_index(note)

      # Postgres chunks should be gone
      import Ecto.Query

      chunks =
        Engram.Repo.all(from(c in Engram.Notes.Chunk, where: c.note_id == ^note.id),
          skip_tenant_check: true
        )

      assert chunks == []
    end
  end
end
