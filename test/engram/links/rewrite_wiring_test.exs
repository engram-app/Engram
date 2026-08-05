defmodule Engram.Links.RewriteWiringTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Attachments
  alias Engram.MCP.Handlers
  alias Engram.Notes
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

    test "untagged relocate enqueues NOTHING while the compromise flag holds",
         %{user: user, vault: vault, note: note} do
      # Pinned to Notes.untagged_crdt_client_type/0 == "obsidian" (see
      # notes_crdt_origin_gate_test.exs). When the flag flips to "web", this
      # test flips to assert [_] = all_enqueued(...) in the same commit.
      {:ok, _} = Notes.genesis_crdt_note(user, vault, note.id, "Fresh.md")
      assert all_enqueued(worker: RewriteNoteLinks) == []
    end

    test "same-path idempotent re-genesis enqueues nothing even for web origin",
         %{user: user, vault: vault, note: note} do
      {:ok, _} = Notes.genesis_crdt_note(user, vault, note.id, "Old.md", origin: "web")
      assert all_enqueued(worker: RewriteNoteLinks) == []
    end
  end
end
