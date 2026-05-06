defmodule Engram.Workers.EmbedNoteTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Mox

  alias Engram.Crypto
  alias Engram.Crypto.DekCache
  alias Engram.Notes
  alias Engram.Notes.Note
  alias Engram.Workers.EmbedNote
  alias Engram.Repo

  setup :verify_on_exit!

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user)

    # Phase B.3 requires Phase B ciphertext on every note row, so go through
    # the public upsert path rather than the raw factory shortcut.
    note =
      Engram.Fixtures.insert_note!(user, vault, %{
        path: "Test/Hello.md",
        content: "# Hello\n\nWorld."
      })

    %{bypass: bypass, user: user, vault: vault, note: note}
  end

  defp stub_qdrant(bypass) do
    Bypass.expect(bypass, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true}))
    end)
  end

  describe "perform/1" do
    test "indexes note and returns :ok", %{bypass: bypass, note: note} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn texts ->
        {:ok, Enum.map(texts, fn _ -> List.duplicate(0.1, 3) end)}
      end)

      stub_qdrant(bypass)

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})
    end

    test "stamps embed_hash on success", %{bypass: bypass, note: note} do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn texts ->
        {:ok, Enum.map(texts, fn _ -> List.duplicate(0.1, 3) end)}
      end)

      stub_qdrant(bypass)

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})

      updated = Repo.get!(Note, note.id, skip_tenant_check: true)
      assert updated.embed_hash == updated.content_hash
    end

    test "skips embedding when embed_hash matches content_hash", %{note: note} do
      # Pre-set embed_hash to match content_hash
      import Ecto.Query

      from(n in Note, where: n.id == ^note.id)
      |> Repo.update_all([set: [embed_hash: note.content_hash]], skip_tenant_check: true)

      # No mock expectations — if it tried to embed, Mox would fail
      assert :ok = perform_job(EmbedNote, %{note_id: note.id})
    end

    test "optimistic lock: does not stamp embed_hash if content changed mid-embed", %{
      bypass: bypass,
      note: note
    } do
      Engram.MockEmbedder
      |> expect(:embed_texts, fn texts ->
        # Simulate concurrent edit: change content_hash while embedding
        import Ecto.Query

        from(n in Note, where: n.id == ^note.id)
        |> Repo.update_all([set: [content_hash: "changed_during_embed"]],
          skip_tenant_check: true
        )

        {:ok, Enum.map(texts, fn _ -> List.duplicate(0.1, 3) end)}
      end)

      stub_qdrant(bypass)

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})

      updated = Repo.get!(Note, note.id, skip_tenant_check: true)
      # embed_hash should NOT have been set (content_hash changed)
      assert is_nil(updated.embed_hash)
    end

    test "discards job when note doesn't exist" do
      assert {:discard, _} = perform_job(EmbedNote, %{note_id: 999_999})
    end

    test "discards job when note is soft-deleted", %{user: user} do
      note = insert(:note, user: user, deleted_at: DateTime.utc_now())
      assert {:discard, _} = perform_job(EmbedNote, %{note_id: note.id})
    end

    test "decrypts content before indexing for encrypted vault", %{bypass: bypass} do
      DekCache.invalidate_all()

      user = insert(:user)
      {:ok, user} = Crypto.ensure_user_dek(user)
      vault = insert(:vault, user: user)

      # upsert_note encrypts content on the way in
      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "secure/secret.md",
          "content" => "# Secret\n\nClassified content.",
          "mtime" => 1_000.0
        })

      # Embedder should receive non-empty texts (plaintext chunks, not "")
      Engram.MockEmbedder
      |> expect(:embed_texts, fn texts ->
        # texts come from Markdown.parse on the decrypted content — must be non-empty
        assert texts != []
        assert Enum.all?(texts, fn t -> is_binary(t) and t != "" end)
        {:ok, Enum.map(texts, fn _ -> List.duplicate(0.1, 3) end)}
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

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})

      # Confirms the worker loaded the (encrypted) vault and passed it into the
      # indexing pipeline: payloads must carry nonces and ciphertext, not plaintext.
      assert_received {:upsert_body, body}
      points = body["points"]
      assert length(points) > 0

      Enum.each(points, fn p ->
        payload = p["payload"]
        assert Map.has_key?(payload, "text_nonce")
        assert Map.has_key?(payload, "title_nonce")
        refute payload["text"] =~ "Classified"
      end)

      # embed_hash should be stamped, confirming the job ran to completion
      updated = Repo.get!(Note, note.id, skip_tenant_check: true)
      assert updated.embed_hash == updated.content_hash
    end
  end

  describe "job scheduling" do
    test "Notes.upsert_note enqueues EmbedNote job", %{user: user, vault: vault} do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "Test/Scheduled.md",
          "content" => "# Scheduled",
          "mtime" => 1_000.0
        })

      # Oban is in :manual mode globally — jobs stay in 'scheduled' state for assertion
      assert_enqueued(worker: EmbedNote, args: %{"note_id" => note.id})
    end

    test "upsert with unchanged content does not enqueue embed job", %{user: user, vault: vault} do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "Test/NoChange.md",
          "content" => "# Same content",
          "mtime" => 1_000.0
        })

      # First upsert triggers embed
      assert_enqueued(worker: EmbedNote, args: %{"note_id" => note.id})

      # Re-upsert with same content — should not enqueue another
      {:ok, _} =
        Notes.upsert_note(user, vault, %{
          "path" => "Test/NoChange.md",
          "content" => "# Same content",
          "mtime" => 2_000.0
        })

      # Still only one job
      jobs = all_enqueued(worker: EmbedNote)
      assert length(jobs) == 1
    end

    test "delete_note does not enqueue an additional embed job", %{
      bypass: bypass,
      user: user,
      vault: vault
    } do
      # Stub all Qdrant requests — the background delete_note_index Task may hit Qdrant
      Bypass.stub(bypass, "POST", "/collections/engram_notes/points/delete", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": {"status": "ok"}}))
      end)

      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "Test/Gone.md",
          "content" => "# Gone",
          "mtime" => 1_000.0
        })

      Notes.delete_note(user, vault, note.path)
      # Allow the background Task to complete before checking job count
      Process.sleep(100)

      # Only the upsert job, nothing from delete
      jobs = all_enqueued(worker: EmbedNote)
      assert length(jobs) == 1
    end
  end
end
