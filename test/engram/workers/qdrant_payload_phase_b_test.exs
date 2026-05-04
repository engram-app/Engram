defmodule Engram.Workers.QdrantPayloadPhaseBTest do
  @moduledoc """
  Phase B.2.5 — re-upsert worker drives `Qdrant.set_payload` (PATCH) for every
  pre-Phase-B point so HMAC keys land in Qdrant payloads without paying for
  Voyage re-embedding. Cursor-driven, idempotent on retry.
  """

  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Notes
  alias Engram.Notes.Chunk
  alias Engram.Repo
  alias Engram.Workers.QdrantPayloadPhaseB

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    {:ok, user} = insert(:user) |> Engram.Crypto.ensure_user_dek()
    vault = insert(:vault, user: user)
    %{bypass: bypass, user: user, vault: vault}
  end

  describe "perform/1" do
    test "PATCHes path_hmac/folder_hmac/tags_hmac onto every chunk point of every note",
         %{bypass: bypass, user: user, vault: vault} do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "Health/Iron Panel.md",
          "content" => "---\ntags: [health, labs]\n---\n# Iron Panel\n\nFerritin levels."
        })

      # Insert two chunk rows with known qdrant_point_ids so we can assert the
      # PATCH targets exactly those ids. Bypass schema-level constraints with
      # skip_tenant_check (this is a test fixture, not a tenant operation).
      point_id_1 = Ecto.UUID.generate()
      point_id_2 = Ecto.UUID.generate()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert_all(
        Chunk,
        [
          %{
            note_id: note.id,
            user_id: user.id,
            vault_id: vault.id,
            position: 0,
            heading_path: "Iron Panel",
            char_start: 0,
            char_end: 10,
            qdrant_point_id: point_id_1,
            created_at: now
          },
          %{
            note_id: note.id,
            user_id: user.id,
            vault_id: vault.id,
            position: 1,
            heading_path: "Iron Panel",
            char_start: 10,
            char_end: 20,
            qdrant_point_id: point_id_2,
            created_at: now
          }
        ],
        skip_tenant_check: true
      )

      test_pid = self()

      Bypass.expect(bypass, "POST", "/collections/engram_notes/points/payload", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:set_payload, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": {"status": "acknowledged"}}))
      end)

      :ok =
        perform_job(QdrantPayloadPhaseB, %{
          "user_id" => user.id,
          "vault_id" => vault.id,
          "last_id" => 0
        })

      assert_receive {:set_payload, decoded}, 1_000

      assert Enum.sort(decoded["points"]) == Enum.sort([point_id_1, point_id_2])

      payload = decoded["payload"]
      assert is_binary(payload["path_hmac"])
      assert is_binary(payload["folder_hmac"])
      assert is_list(payload["tags_hmac"])
      assert length(payload["tags_hmac"]) == 2

      # The HMACs in the payload must equal the base64-encoded values stored on
      # the note row (Phase B.1 backfill is the source of truth for HMACs).
      reloaded = Repo.get!(Engram.Notes.Note, note.id, skip_tenant_check: true)
      assert payload["path_hmac"] == Base.encode64(reloaded.path_hmac)
      assert payload["folder_hmac"] == Base.encode64(reloaded.folder_hmac)

      assert Enum.sort(payload["tags_hmac"]) ==
               Enum.sort(Enum.map(reloaded.tags_hmac, &Base.encode64/1))
    end

    test "skips notes with no chunks (no PATCH call)", %{bypass: bypass, user: user, vault: vault} do
      # upsert_note populates path_hmac etc but does not synchronously create
      # chunks (those come via EmbedNote async). So this note has zero chunks.
      {:ok, _note} =
        Notes.upsert_note(user, vault, %{
          "path" => "empty.md",
          "content" => "x",
          "tags" => []
        })

      Bypass.stub(bypass, "POST", "/collections/engram_notes/points/payload", fn _ ->
        flunk("set_payload must not be called when a note has no chunks")
      end)

      :ok =
        perform_job(QdrantPayloadPhaseB, %{
          "user_id" => user.id,
          "vault_id" => vault.id,
          "last_id" => 0
        })
    end

    test "re-enqueues with new cursor when batch is full",
         %{bypass: bypass, user: user, vault: vault} do
      # Fill a batch (100). No chunks needed — the cursor advances on note ids
      # regardless of whether each note had any Qdrant points.
      for i <- 1..100 do
        {:ok, _} =
          Notes.upsert_note(user, vault, %{
            "path" => "batch/n-#{i}.md",
            "content" => "c",
            "tags" => []
          })
      end

      Bypass.stub(bypass, "POST", "/collections/engram_notes/points/payload", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": {"status": "acknowledged"}}))
      end)

      :ok =
        perform_job(QdrantPayloadPhaseB, %{
          "user_id" => user.id,
          "vault_id" => vault.id,
          "last_id" => 0
        })

      assert_enqueued(worker: QdrantPayloadPhaseB)
    end

    test "returns :ok and does not re-enqueue when batch is empty",
         %{bypass: bypass, user: user, vault: vault} do
      Bypass.stub(bypass, "POST", "/collections/engram_notes/points/payload", fn _ ->
        flunk("Qdrant must not be called for an empty batch")
      end)

      :ok =
        perform_job(QdrantPayloadPhaseB, %{
          "user_id" => user.id,
          "vault_id" => vault.id,
          "last_id" => 0
        })

      refute_enqueued(worker: QdrantPayloadPhaseB)
    end

    test "is idempotent — second run with same cursor is a no-op for already-walked notes",
         %{bypass: bypass, user: user, vault: vault} do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "idem.md",
          "content" => "c",
          "tags" => ["t"]
        })

      point_id = Ecto.UUID.generate()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert_all(
        Chunk,
        [
          %{
            note_id: note.id,
            user_id: user.id,
            vault_id: vault.id,
            position: 0,
            heading_path: "h",
            char_start: 0,
            char_end: 1,
            qdrant_point_id: point_id,
            created_at: now
          }
        ],
        skip_tenant_check: true
      )

      call_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "POST", "/collections/engram_notes/points/payload", fn conn ->
        :counters.add(call_count, 1, 1)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": {"status": "acknowledged"}}))
      end)

      # First run — patches the one note.
      :ok =
        perform_job(QdrantPayloadPhaseB, %{
          "user_id" => user.id,
          "vault_id" => vault.id,
          "last_id" => 0
        })

      assert :counters.get(call_count, 1) == 1

      # Resume from past the last walked id — should be a no-op.
      last = note.id

      :ok =
        perform_job(QdrantPayloadPhaseB, %{
          "user_id" => user.id,
          "vault_id" => vault.id,
          "last_id" => last
        })

      assert :counters.get(call_count, 1) == 1
    end
  end
end
