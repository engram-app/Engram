defmodule Engram.NotesBroadcastSeqTest do
  @moduledoc """
  Every note `note_changed` broadcast carries the committed `seq` of the
  write it announces (#609, Engram-obsidian#642), the same value a later seq
  replay returns, so a client can fence a stale pre-delete upsert against a
  delete exactly. One builder sets it (`Notes.broadcast_change/6`).
  """
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Engram.{Attachments, Folders, Notes, Repo}
  alias Engram.Attachments.Attachment
  alias Engram.Notes.Note

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")
    %{user: user, vault: vault}
  end

  defp put_note(user, vault, path) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => "x #{path}"}, actor: "api")

    note
  end

  defp row_seq(id),
    do: Repo.one!(from(n in Note, where: n.id == ^id, select: n.seq), skip_tenant_check: true)

  # The seq a replay from zero serves for this note id (live or tombstone).
  defp replay_seq(user, vault, id) do
    {:ok, %{changes: changes}} = Notes.list_changes_by_seq(user, vault, 0, fields: :meta)
    changes |> Enum.filter(&(&1[:id] == id)) |> Enum.map(& &1.seq) |> Enum.max(fn -> nil end)
  end

  defp next_event(type, path) do
    assert_receive %Phoenix.Socket.Broadcast{
      event: "note_changed",
      payload: %{"event_type" => ^type, "path" => ^path} = payload
    }

    payload
  end

  defp drain, do: receive(do: (%Phoenix.Socket.Broadcast{} -> drain()), after: (50 -> :ok))

  test "an upsert carries the written row's seq", %{user: user, vault: vault} do
    note = put_note(user, vault, "a.md")
    payload = next_event("upsert", "a.md")

    assert payload["seq"] == row_seq(note.id)
    assert payload["seq"] == replay_seq(user, vault, note.id)
  end

  test "a delete carries the tombstone's seq", %{user: user, vault: vault} do
    note = put_note(user, vault, "a.md")
    drain()

    :deleted = Notes.delete_note_reporting(user, vault, "a.md")
    payload = next_event("delete", "a.md")

    assert is_integer(payload["seq"])
    assert payload["seq"] == row_seq(note.id)
    assert payload["seq"] == replay_seq(user, vault, note.id)
  end

  test "a folder delete and a batch delete carry the tombstones' seq", %{
    user: user,
    vault: vault
  } do
    a = put_note(user, vault, "Docs/a.md")
    b = put_note(user, vault, "b.md")
    {:ok, _} = Notes.create_folder_markers(user, vault, ["Docs/Empty"])
    drain()

    {:ok, _} = Folders.delete(user, vault, "Docs", recursive: true)
    note_evt = next_event("delete", "Docs/a.md")
    marker_evt = next_event("delete", "Docs/Empty")
    assert note_evt["seq"] == row_seq(a.id)
    assert is_integer(marker_evt["seq"])

    {:ok, %{deleted: 1}} = Notes.batch_delete_notes(user, vault, [b.id])
    assert next_event("delete", "b.md")["seq"] == row_seq(b.id)
  end

  test "both legs of a rename carry the rename's seq", %{user: user, vault: vault} do
    note = put_note(user, vault, "old.md")
    drain()

    {:ok, _} = Notes.rename_note(user, vault, "old.md", "new.md")
    up = next_event("upsert", "new.md")
    del = next_event("delete", "old.md")

    assert up["seq"] == row_seq(note.id)
    assert del["seq"] == up["seq"]
  end

  test "a folder rename cascade carries its one seq on both legs", %{user: user, vault: vault} do
    note = put_note(user, vault, "Old/a.md")
    drain()

    {:ok, _} = Folders.rename(user, vault, "Old", "New")
    up = next_event("upsert", "New/a.md")
    del = next_event("delete", "Old/a.md")

    assert up["seq"] == row_seq(note.id)
    assert del["seq"] == up["seq"]
  end

  test "a restore upsert carries the restored row's seq", %{user: user, vault: vault} do
    note = put_note(user, vault, "a.md")
    op = Ecto.UUID.generate()
    :deleted = Notes.delete_note_reporting(user, vault, "a.md", op_id: op)
    drain()

    {:ok, %{notes: 1}} = Folders.restore_op(user, vault, op)
    payload = next_event("upsert", "a.md")

    assert payload["seq"] == row_seq(note.id)
    assert payload["seq"] == replay_seq(user, vault, note.id)
  end

  test "a CRDT relocate carries the rename's seq on both legs", %{user: user, vault: vault} do
    note = put_note(user, vault, "Old.md")
    drain()

    {:ok, _} = Notes.genesis_crdt_note(user, vault, note.id, "New.md")
    up = next_event("upsert", "New.md")
    del = next_event("delete", "Old.md")

    assert up["seq"] == row_seq(note.id)
    assert del["seq"] == up["seq"]
  end

  describe "attachment events" do
    defp put_att(user, vault, path) do
      {:ok, att} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => path,
          "content_base64" => Base.encode64("bytes of " <> path)
        })

      att
    end

    defp att_seq(id),
      do:
        Repo.one!(from(a in Attachment, where: a.id == ^id, select: a.seq),
          skip_tenant_check: true
        )

    test "upsert, delete, batch delete and restore carry the committed seq", %{
      user: user,
      vault: vault
    } do
      a = put_att(user, vault, "a.png")
      assert next_event("upsert", "a.png")["seq"] == att_seq(a.id)

      op = Ecto.UUID.generate()
      :deleted = Attachments.delete_attachment_reporting(user, vault, "a.png", op_id: op)
      assert next_event("delete", "a.png")["seq"] == att_seq(a.id)

      {:ok, %{attachments: 1}} = Folders.restore_op(user, vault, op)
      assert next_event("upsert", "a.png")["seq"] == att_seq(a.id)

      {:ok, %{deleted: 1}} = Attachments.batch_delete(user, vault, ["a.png"])
      assert next_event("delete", "a.png")["seq"] == att_seq(a.id)
    end

    test "both legs of an attachment move carry the move's seq", %{user: user, vault: vault} do
      a = put_att(user, vault, "a.png")
      drain()

      {:ok, _} = Attachments.move_attachment(user, vault, "a.png", "b.png")
      del = next_event("delete", "a.png")
      up = next_event("upsert", "b.png")

      assert up["seq"] == att_seq(a.id)
      assert del["seq"] == up["seq"]
    end
  end
end
