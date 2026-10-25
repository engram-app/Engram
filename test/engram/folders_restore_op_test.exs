defmodule Engram.FoldersRestoreOpTest do
  @moduledoc """
  Safer delete (#609): `Folders.restore_op/3` brings back exactly the rows
  one undoable delete stamped, at their own paths, and refuses before
  restoring anything when the result would pass a plan cap.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query

  alias Engram.{Attachments, Folders, Notes, Repo, Storage}
  alias Engram.Attachments.Attachment
  alias Engram.Notes.Note

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp put_note(user, vault, path, content \\ "body") do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => content}, actor: "api")

    note
  end

  defp put_att(user, vault, path) do
    {:ok, att} =
      Attachments.upsert_attachment(user, vault, %{
        "path" => path,
        "content_base64" => Base.encode64("bytes of " <> path)
      })

    Repo.get!(Attachment, att.id, skip_tenant_check: true)
  end

  defp note_row(id), do: Repo.get!(Note, id, skip_tenant_check: true)
  defp att_row(id), do: Repo.get!(Attachment, id, skip_tenant_check: true)

  defp live_paths(user, vault) do
    {:ok, metas} = Attachments.list_attachments(user, vault)

    notes =
      Repo.all(from(n in Notes.scoped_live(user, vault), where: n.kind == "note"),
        skip_tenant_check: true
      )

    %{notes: length(notes), attachments: metas |> Enum.map(& &1.path) |> Enum.sort()}
  end

  test "a recursive folder delete comes back whole", %{user: user, vault: vault} do
    note = put_note(user, vault, "Docs/n.md", "hello")
    att = put_att(user, vault, "Docs/a.png")
    {:ok, _} = Notes.create_folder_markers(user, vault, ["Docs/Empty"])
    op = Ecto.UUID.generate()

    {:ok, %{notes: 1, attachments: 1}} =
      Folders.delete(user, vault, "Docs", recursive: true, op_id: op)

    deleted_seq = note_row(note.id).seq

    assert {:ok, %{notes: 1, attachments: 1, folders: folders, skipped: []}} =
             Folders.restore_op(user, vault, op)

    # "Docs" itself (if it had a marker) and "Docs/Empty".
    assert folders >= 1

    restored = note_row(note.id)
    assert is_nil(restored.deleted_at)
    assert is_nil(restored.delete_op_id)
    assert restored.seq > deleted_seq
    assert {:ok, %{content: "hello"}} = Notes.get_note(user, vault, "Docs/n.md")

    assert is_nil(att_row(att.id).deleted_at)
    assert match?({:ok, _}, Storage.adapter().get(att.storage_key))
    assert {:ok, folder_names} = Notes.list_explicit_folders(user, vault)
    assert "Docs/Empty" in folder_names

    # Its Qdrant points went with the delete, so it is queued to re-embed.
    assert Enum.any?(
             all_enqueued(worker: Engram.Workers.EmbedNote),
             &(&1.args["note_id"] == note.id)
           )

    # Idempotent: the rows left the op.
    assert {:ok, %{notes: 0, attachments: 0, folders: 0, skipped: []}} =
             Folders.restore_op(user, vault, op)
  end

  @tag timeout: 300_000
  test "restores a chunked delete of more than 1,000 items", %{user: user, vault: vault} do
    for i <- 1..1_001, do: put_att(user, vault, "Big/a#{i}.png")
    # Past the 100-note restore chunk.
    for i <- 1..120, do: put_note(user, vault, "Big/n#{i}.md")
    op = Ecto.UUID.generate()

    {:ok, %{notes: 120, attachments: 1_001}} =
      Folders.delete(user, vault, "Big", recursive: true, op_id: op)

    assert %{notes: 0, attachments: []} = live_paths(user, vault)

    assert {:ok, %{notes: 120, attachments: 1_001, skipped: []}} =
             Folders.restore_op(user, vault, op)

    assert %{notes: 120, attachments: paths} = live_paths(user, vault)
    assert length(paths) == 1_001
  end

  test "a path a live row took since is skipped and reported", %{user: user, vault: vault} do
    old_note = put_note(user, vault, "a.md", "old")
    old_att = put_att(user, vault, "a.png")
    keep = put_note(user, vault, "b.md")
    op = Ecto.UUID.generate()

    :deleted = Notes.delete_note_reporting(user, vault, "a.md", op_id: op)
    :deleted = Notes.delete_note_reporting(user, vault, "b.md", op_id: op)
    :deleted = Attachments.delete_attachment_reporting(user, vault, "a.png", op_id: op)

    new_note = put_note(user, vault, "a.md", "new")
    _new_att = put_att(user, vault, "a.png")

    assert {:ok, %{notes: 1, attachments: 0, skipped: skipped}} =
             Folders.restore_op(user, vault, op)

    assert %{path: "a.md", kind: "note", reason: :path_taken} in skipped
    assert %{path: "a.png", kind: "attachment", reason: :path_taken} in skipped

    assert note_row(old_note.id).deleted_at
    assert att_row(old_att.id).deleted_at
    assert is_nil(note_row(keep.id).deleted_at)
    assert {:ok, %{id: id, content: "new"}} = Notes.get_note(user, vault, "a.md")
    assert id == new_note.id
  end

  test "restoring past notes_cap refuses and restores nothing", %{user: user, vault: vault} do
    insert(:user_limit_override, user: user, key: "notes_cap", value: %{"v" => 2})
    a = put_note(user, vault, "a.md")
    _b = put_note(user, vault, "b.md")
    op = Ecto.UUID.generate()
    :deleted = Notes.delete_note_reporting(user, vault, "a.md", op_id: op)
    :deleted = Notes.delete_note_reporting(user, vault, "b.md", op_id: op)
    _c = put_note(user, vault, "c.md")

    assert {:error, {:limit_reached, :notes_cap, 2, 1}} = Folders.restore_op(user, vault, op)
    assert note_row(a.id).deleted_at
    assert note_row(a.id).delete_op_id == op
  end

  test "restoring past the storage quota refuses", %{user: user, vault: vault} do
    # Room for one of these files, not two. Set before any upload, so no
    # cached lookup predates it.
    size = byte_size("bytes of a.png")

    insert(:user_limit_override,
      user: user,
      key: "attachment_bytes_cap",
      value: %{"v" => size + div(size, 2)}
    )

    att = put_att(user, vault, "a.png")
    op = Ecto.UUID.generate()
    :deleted = Attachments.delete_attachment_reporting(user, vault, "a.png", op_id: op)
    _other = put_att(user, vault, "b.png")

    assert {:error, {:limit_reached, :attachment_bytes_cap, _, _}} =
             Folders.restore_op(user, vault, op)

    assert att_row(att.id).deleted_at
  end

  test "an op id never covers a rename tombstone", %{user: user, vault: vault} do
    note = put_note(user, vault, "old.md")
    {:ok, _} = Notes.rename_note(user, vault, "old.md", "new.md")
    op = Ecto.UUID.generate()
    :deleted = Notes.delete_note_reporting(user, vault, "new.md", op_id: op)

    assert {:ok, %{notes: 1}} = Folders.restore_op(user, vault, op)
    assert {:ok, %{id: id}} = Notes.get_note(user, vault, "new.md")
    assert id == note.id
    assert {:error, :not_found} = Notes.get_note(user, vault, "old.md")
  end

  test "a row past trash retention is skipped as expired", %{user: user, vault: vault} do
    note = put_note(user, vault, "old.md")
    att = put_att(user, vault, "old.png")
    op = Ecto.UUID.generate()
    :deleted = Notes.delete_note_reporting(user, vault, "old.md", op_id: op)
    :deleted = Attachments.delete_attachment_reporting(user, vault, "old.png", op_id: op)
    # Free keeps trash 7 days.
    long_ago = DateTime.add(DateTime.utc_now(:second), -8, :day)

    {1, _} =
      Repo.update_all(from(n in Note, where: n.id == ^note.id), [set: [deleted_at: long_ago]],
        skip_tenant_check: true
      )

    {1, _} =
      Repo.update_all(
        from(a in Attachment, where: a.id == ^att.id),
        [set: [deleted_at: long_ago]],
        skip_tenant_check: true
      )

    assert {:ok, %{notes: 0, attachments: 0, skipped: skipped}} =
             Folders.restore_op(user, vault, op)

    assert %{id: note.id, kind: "note", reason: :expired} in skipped
    assert %{id: att.id, kind: "attachment", reason: :expired} in skipped
    assert note_row(note.id).deleted_at
  end

  test "a malformed op id is refused", %{user: user, vault: vault} do
    assert {:error, :invalid_op_id} = Folders.restore_op(user, vault, "not-a-uuid")
  end

  describe "tenant isolation (RLS)" do
    import Engram.RlsCase

    setup %{user: user, vault: vault} do
      note = put_note(user, vault, "secret.md")
      op = Ecto.UUID.generate()
      :deleted = Notes.delete_note_reporting(user, vault, "secret.md", op_id: op)
      {:ok, other} = Engram.Fixtures.user_with_dek_fixture()
      other_vault = insert(:vault, user: other)
      %{note: note, op: op, other: other, other_vault: other_vault}
    end

    # CONTROL: proves the dropped role is engaged. Without it a green below is
    # ambiguous between "scoped" and "the role drop never happened".
    test "control: the dropped role with no tenant sees zero note rows", %{note: note} do
      assert {:returned, []} =
               as_prod_role(fn ->
                 Repo.all(from(n in Note, where: n.id == ^note.id), skip_tenant_check: true)
               end)
    end

    test "another user's op id restores nothing, even naming the owner's vault", %{
      note: note,
      op: op,
      other: other,
      vault: vault,
      other_vault: other_vault
    } do
      # Precondition: the row IS tombstoned under this op.
      assert note_row(note.id).delete_op_id == op

      for v <- [vault, other_vault] do
        assert {:ok, %{notes: 0, attachments: 0, folders: 0, skipped: []}} =
                 as_prod_role_committing(fn -> Folders.restore_op(other, v, op) end)
      end

      # Persisted effect, read outside the role: still in the owner's trash.
      row = note_row(note.id)
      assert row.deleted_at
      assert row.delete_op_id == op
    end
  end
end
