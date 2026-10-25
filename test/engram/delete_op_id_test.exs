defmodule Engram.DeleteOpIdTest do
  @moduledoc """
  Safer delete (#609): a delete given `op_id:` stamps exactly the rows IT
  soft-deleted, so `Folders.restore_op/3` can bring back that call and
  nothing else. Rename tombstones are never stamped, a row deleted by an
  earlier call keeps that call's id, and any undelete clears the stamp.
  """
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Engram.{Attachments, Folders, Notes, Repo}
  alias Engram.Attachments.Attachment
  alias Engram.Notes.Note

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp put_note(user, vault, path) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => "x"}, actor: "api")

    note
  end

  defp put_att(user, vault, path) do
    {:ok, att} =
      Attachments.upsert_attachment(user, vault, %{
        "path" => path,
        "content_base64" => Base.encode64("x")
      })

    att
  end

  defp op_of(Note, id), do: Repo.get!(Note, id, skip_tenant_check: true).delete_op_id
  defp op_of(Attachment, id), do: Repo.get!(Attachment, id, skip_tenant_check: true).delete_op_id

  defp stamped(schema, vault, op) do
    Repo.all(
      from(r in schema, where: r.vault_id == ^vault.id and r.delete_op_id == ^op, select: r.id),
      skip_tenant_check: true
    )
    |> Enum.sort()
  end

  test "delete_note stamps its op id; a delete without one stamps nothing", %{
    user: user,
    vault: vault
  } do
    a = put_note(user, vault, "a.md")
    b = put_note(user, vault, "b.md")
    op = Ecto.UUID.generate()

    assert :deleted = Notes.delete_note_reporting(user, vault, "a.md", op_id: op)
    assert :deleted = Notes.delete_note_reporting(user, vault, "b.md")

    assert op_of(Note, a.id) == op
    assert is_nil(op_of(Note, b.id))
  end

  test "delete_attachment stamps its op id", %{user: user, vault: vault} do
    att = put_att(user, vault, "a.png")
    op = Ecto.UUID.generate()

    assert :deleted = Attachments.delete_attachment_reporting(user, vault, "a.png", op_id: op)
    assert op_of(Attachment, att.id) == op
  end

  test "a recursive folder delete stamps notes, markers and attachments", %{
    user: user,
    vault: vault
  } do
    n = put_note(user, vault, "Docs/n.md")
    att = put_att(user, vault, "Docs/a.png")
    {:ok, _} = Notes.create_folder_markers(user, vault, ["Docs", "Docs/Empty"])
    op = Ecto.UUID.generate()

    assert {:ok, %{notes: 1, attachments: 1}} =
             Folders.delete(user, vault, "Docs", recursive: true, op_id: op)

    note_rows = stamped(Note, vault, op)
    assert n.id in note_rows
    # The note plus both markers.
    assert length(note_rows) == 3
    assert stamped(Attachment, vault, op) == [att.id]
  end

  # A retry (or a second delete over an overlapping tree) only stamps what
  # IT deleted: rows a previous call already removed keep that call's id, so
  # undoing either call restores exactly its own rows.
  test "a retried delete keeps each call's own op id", %{user: user, vault: vault} do
    first = put_note(user, vault, "Docs/a.md")
    second = put_note(user, vault, "Docs/b.md")
    op1 = Ecto.UUID.generate()
    op2 = Ecto.UUID.generate()

    assert :deleted = Notes.delete_note_reporting(user, vault, "Docs/a.md", op_id: op1)
    assert {:ok, %{notes: 1}} = Folders.delete(user, vault, "Docs", recursive: true, op_id: op2)

    assert op_of(Note, first.id) == op1
    assert op_of(Note, second.id) == op2
  end

  test "rename tombstones are never stamped", %{user: user, vault: vault} do
    note = put_note(user, vault, "old.md")
    {:ok, _} = Notes.rename_note(user, vault, "old.md", "new.md")
    att = put_att(user, vault, "old.png")
    {:ok, _} = Attachments.move_attachment(user, vault, "old.png", "new.png")
    op = Ecto.UUID.generate()

    assert :deleted = Notes.delete_note_reporting(user, vault, "new.md", op_id: op)
    assert :deleted = Attachments.delete_attachment_reporting(user, vault, "new.png", op_id: op)

    assert stamped(Note, vault, op) == [note.id]
    assert stamped(Attachment, vault, op) == [att.id]

    # The rename legs left tombstones at the old paths; none carries an op.
    assert Repo.aggregate(
             from(n in Note,
               where: n.vault_id == ^vault.id and not is_nil(n.deleted_at) and n.id != ^note.id
             ),
             :count,
             skip_tenant_check: true
           ) == 1

    assert Repo.aggregate(
             from(n in Note,
               where: n.vault_id == ^vault.id and not is_nil(n.delete_op_id) and n.id != ^note.id
             ),
             :count,
             skip_tenant_check: true
           ) == 0
  end

  test "undeleting a folder marker clears its stamp", %{user: user, vault: vault} do
    {:ok, _} = Notes.create_folder_markers(user, vault, ["Docs"])
    op = Ecto.UUID.generate()
    {:ok, _} = Folders.delete(user, vault, "Docs", op_id: op)
    [marker_id] = stamped(Note, vault, op)

    {:ok, _} = Notes.create_folder_markers(user, vault, ["Docs"])

    marker = Repo.get!(Note, marker_id, skip_tenant_check: true)
    assert is_nil(marker.deleted_at)
    assert is_nil(marker.delete_op_id)
  end
end
