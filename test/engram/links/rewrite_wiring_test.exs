defmodule Engram.Links.RewriteWiringTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Attachments
  alias Engram.Folders
  alias Engram.MCP.Handlers
  alias Engram.Notes
  alias Engram.Workers.RebindNoteLinks
  alias Engram.Workers.RewriteNoteLinks

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  test "REST-origin note rename enqueues a rewrite job with hmac-only args", %{
    user: user,
    vault: vault
  } do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "Old.md", "content" => "# t"})
    {:ok, _} = Notes.rename_note(user, vault, "Old.md", "Fresh.md")

    assert [job] = all_enqueued(worker: RewriteNoteLinks)
    assert job.args["target_kind"] == "note"
    assert job.args["target_id"] == note.id
    assert {:ok, _} = Base.decode64(job.args["old_path_hmac"])
    assert {:ok, _} = Base.decode64(job.args["old_basename_hmac"])
    refute Map.has_key?(job.args, "old_path")
  end

  test "no-op rename (same path) enqueues nothing", %{user: user, vault: vault} do
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "Same.md", "content" => "x"})
    {:ok, _} = Notes.rename_note(user, vault, "Same.md", "Same.md")

    assert all_enqueued(worker: RewriteNoteLinks) == []
  end

  test "attachment move enqueues a rewrite job", %{user: user, vault: vault} do
    att = Engram.Fixtures.insert_attachment!(user, vault, %{path: "img/old.png"})
    {:ok, _} = Attachments.move_attachment(user, vault, "img/old.png", "img/new.png")

    assert [job] = all_enqueued(worker: RewriteNoteLinks)
    assert job.args["target_kind"] == "attachment"
    assert job.args["target_id"] == att.id
  end

  test "MCP rename_note routes through Notes.rename_note — same enqueue, no extra wiring", %{
    user: user,
    vault: vault
  } do
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "McpOld.md", "content" => "x"})

    {:ok, _msg} =
      Handlers.handle("rename_note", user, vault, %{
        "old_path" => "McpOld.md",
        "new_path" => "McpNew.md"
      })

    assert [_job] = all_enqueued(worker: RewriteNoteLinks)
  end

  test "MCP move_attachment routes through Attachments.move_attachment", %{
    user: user,
    vault: vault
  } do
    _att = Engram.Fixtures.insert_attachment!(user, vault, %{path: "m/old.png"})

    {:ok, _msg} =
      Handlers.handle("move_attachment", user, vault, %{
        "old_path" => "m/old.png",
        "new_path" => "m/new.png"
      })

    assert [_job] = all_enqueued(worker: RewriteNoteLinks)
  end

  test "PromEx indexing plugin exposes the rewrite-failure counter" do
    metrics =
      [otp_app: :engram]
      |> Engram.PromEx.Indexing.event_metrics()
      |> List.wrap()
      |> Enum.flat_map(& &1.metrics)

    assert Enum.any?(metrics, fn m ->
             m.event_name == [:engram, :links, :rewrite, :failed]
           end)
  end

  describe "CRDT-origin gate (Phase 2, #648)" do
    setup %{user: user, vault: vault} do
      {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "Old.md", "content" => "# t"})
      %{note: note}
    end

    test "web-origin relocate enqueues ONE job with encrypted old-path args",
         %{user: user, vault: vault, note: note} do
      {:ok, _} = Notes.genesis_crdt_note(user, vault, note.id, "Fresh.md", origin: "web")

      assert [job] = all_enqueued(worker: RewriteNoteLinks)
      assert job.args["target_kind"] == "note"
      assert job.args["target_id"] == note.id
      assert {:ok, _} = Base.decode64(job.args["old_path_hmac"])
      assert {:ok, _} = Base.decode64(job.args["old_basename_hmac"])
      assert {:ok, _} = Base.decode64(job.args["old_path_ciphertext"])
      assert {:ok, _} = Base.decode64(job.args["old_path_nonce"])
      refute Map.has_key?(job.args, "old_path")
    end

    test "obsidian-origin relocate enqueues NOTHING (one-rewriter invariant)",
         %{user: user, vault: vault, note: note} do
      {:ok, _} = Notes.genesis_crdt_note(user, vault, note.id, "Fresh.md", origin: "obsidian")
      assert all_enqueued(worker: RewriteNoteLinks) == []
    end

    test "untagged relocate enqueues the rewrite (spec safe default)",
         %{user: user, vault: vault, note: note} do
      # Flipped with Notes.untagged_crdt_client_type/0 -> "web" in #1301 (see
      # notes_crdt_origin_gate_test.exs). Untagged is no longer assumed to be a
      # skewed plugin, so the server owns the rewrite for it.
      {:ok, _} = Notes.genesis_crdt_note(user, vault, note.id, "Fresh.md")
      assert [_] = all_enqueued(worker: RewriteNoteLinks)
    end

    test "same-path idempotent re-genesis enqueues nothing even for web origin",
         %{user: user, vault: vault, note: note} do
      {:ok, _} = Notes.genesis_crdt_note(user, vault, note.id, "Old.md", origin: "web")
      assert all_enqueued(worker: RewriteNoteLinks) == []
    end
  end

  describe "folder rename fan-out (Phase 3, #648/#1231)" do
    test "enqueues one rewrite per moved note + one rebind per DISTINCT basename", %{
      user: user,
      vault: vault
    } do
      {:ok, a} = Notes.upsert_note(user, vault, %{"path" => "docs/One.md", "content" => "1"})
      {:ok, b} = Notes.upsert_note(user, vault, %{"path" => "docs/sub/One.md", "content" => "1b"})
      {:ok, c} = Notes.upsert_note(user, vault, %{"path" => "docs/Two.md", "content" => "2"})

      # upsert_note-on-CREATE enqueues its own RebindNoteLinks jobs — count
      # the rename's delta, not absolutes.
      rebinds_before = length(all_enqueued(worker: RebindNoteLinks))

      {:ok, 3} = Notes.rename_folder(user, vault, "docs", "archive")

      rewrite_jobs = all_enqueued(worker: RewriteNoteLinks)
      assert length(rewrite_jobs) == 3

      assert Enum.map(rewrite_jobs, & &1.args["target_id"]) |> Enum.sort() ==
               Enum.sort([a.id, b.id, c.id])

      for job <- rewrite_jobs do
        assert job.args["target_kind"] == "note"
        assert {:ok, _} = Base.decode64(job.args["old_path_hmac"])
        assert {:ok, _} = Base.decode64(job.args["old_basename_hmac"])
        refute Map.has_key?(job.args, "old_path")
        refute Map.has_key?(job.args, "old_path_ciphertext")
      end

      # 3 moved notes, 2 distinct basenames (One.md ×2, Two.md) ⇒ delta 2.
      assert length(all_enqueued(worker: RebindNoteLinks)) - rebinds_before == 2
    end

    test "no-op folder rename (same folder) enqueues no rewrite jobs", %{
      user: user,
      vault: vault
    } do
      {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "keep/N.md", "content" => "n"})
      {:ok, _} = Notes.rename_folder(user, vault, "keep", "keep")

      assert all_enqueued(worker: RewriteNoteLinks) == []
    end

    test "batch folder move fans out through the same seam", %{user: user, vault: vault} do
      {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "src/A.md", "content" => "a"})
      {:ok, marker} = Notes.create_folder_marker(user, vault, "src")

      {:ok, %{moved: 1}} =
        Notes.batch_move_folders(user, vault, [marker.id], {:path, "dst"})

      assert [job] = all_enqueued(worker: RewriteNoteLinks)
      assert job.args["target_id"] == note.id
    end

    test "MCP rename_folder routes through Folders.rename — same fan-out", %{
      user: user,
      vault: vault
    } do
      {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "m/N.md", "content" => "n"})

      {:ok, _msg} =
        Handlers.handle("rename_folder", user, vault, %{
          "old_folder" => "m",
          "new_folder" => "m2"
        })

      assert [_job] = all_enqueued(worker: RewriteNoteLinks)
    end

    test "batch NOTE move already enqueues via rename_note (Phase 1 pin)", %{
      user: user,
      vault: vault
    } do
      {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "bm/N.md", "content" => "n"})

      {:ok, %{moved: 1}} = Notes.batch_move_notes(user, vault, [note.id], {:path, "moved"})

      assert [job] = all_enqueued(worker: RewriteNoteLinks)
      assert job.args["target_id"] == note.id
    end

    test "folder rename cascades attachment rewrites via move_attachment (Phase 1 pin)", %{
      user: user,
      vault: vault
    } do
      _att = Engram.Fixtures.insert_attachment!(user, vault, %{path: "media/img.png"})
      {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "media/N.md", "content" => "n"})

      {:ok, %{notes: 1, attachments: 1}} = Folders.rename(user, vault, "media", "assets")

      kinds =
        all_enqueued(worker: RewriteNoteLinks)
        |> Enum.map(& &1.args["target_kind"])
        |> Enum.sort()

      assert kinds == ["attachment", "note"]
    end
  end
end
