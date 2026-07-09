defmodule Engram.NotesDeleteTombstoneTest do
  @moduledoc """
  Delete-wins-within-a-window: a note re-pushed at a just-deleted path (the
  cross-device resurrection race) must be refused, so an explicit delete is
  not silently undone by a stale re-push from another device.
  """
  use Engram.DataCase, async: true

  alias Engram.Notes
  alias Engram.Notes.Note
  alias Engram.Repo

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Test"})
    %{user: user, vault: vault}
  end

  defp create_and_delete(user, vault, path, content) do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => path, "content" => content})
    :ok = Notes.delete_note(user, vault, path)
    note
  end

  # Force a tombstone's deleted_at into the past to simulate window expiry
  # without sleeping.
  defp backdate_delete(note_id, seconds_ago) do
    past = DateTime.add(DateTime.utc_now(), -seconds_ago, :second)

    from(n in Note, where: n.id == ^note_id)
    |> Repo.update_all([set: [deleted_at: past]], skip_tenant_check: true)
  end

  test "refuses an identical re-push at a just-deleted path (resurrection)", %{
    user: user,
    vault: vault
  } do
    create_and_delete(user, vault, "Folder/Note.md", "# Same body")

    # The resurrecting push carries no client id (plugin dropped the id-map on
    # the delete broadcast) and identical content.
    assert {:error, :recently_deleted} =
             Notes.upsert_note(user, vault, %{
               "path" => "Folder/Note.md",
               "content" => "# Same body"
             })

    # Nothing live at that path — the refusal left no row behind.
    refute Repo.exists?(
             from(n in Note,
               where: n.vault_id == ^vault.id and n.kind == "note" and is_nil(n.deleted_at),
               select: n.id
             ),
             skip_tenant_check: true
           )
  end

  test "allows a genuinely different note re-created at the same path", %{
    user: user,
    vault: vault
  } do
    create_and_delete(user, vault, "Folder/Note.md", "# Old body")

    assert {:ok, note} =
             Notes.upsert_note(user, vault, %{
               "path" => "Folder/Note.md",
               "content" => "# Brand new body"
             })

    assert note.content == "# Brand new body"
  end

  test "allows an identical re-create once the tombstone is older than the window", %{
    user: user,
    vault: vault
  } do
    deleted = create_and_delete(user, vault, "Folder/Note.md", "# Same body")
    backdate_delete(deleted.id, 120)

    assert {:ok, note} =
             Notes.upsert_note(user, vault, %{
               "path" => "Folder/Note.md",
               "content" => "# Same body"
             })

    assert note.content == "# Same body"
  end

  test "batch upsert refuses an identical re-push at a just-deleted path", %{
    user: user,
    vault: vault
  } do
    create_and_delete(user, vault, "Folder/Note.md", "# Same body")

    {:ok, %{results: results}} =
      Notes.batch_upsert_notes(user, vault, [
        %{"path" => "Folder/Note.md", "content" => "# Same body"}
      ])

    assert [%{status: :error, errors: %{reason: "recently_deleted"}}] = results

    refute Repo.exists?(
             from(n in Note,
               where: n.vault_id == ^vault.id and n.kind == "note" and is_nil(n.deleted_at)
             ),
             skip_tenant_check: true
           )
  end

  test "batch upsert still creates a genuinely different note at a deleted path", %{
    user: user,
    vault: vault
  } do
    create_and_delete(user, vault, "Folder/Note.md", "# Old body")

    {:ok, %{results: results}} =
      Notes.batch_upsert_notes(user, vault, [
        %{"path" => "Folder/Note.md", "content" => "# New body"}
      ])

    assert [%{status: :ok}] = results
  end

  test "resurrect-by-id (rename restore) is unaffected by the window", %{
    user: user,
    vault: vault
  } do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "A.md", "content" => "# Body"})

    :ok = Notes.delete_note(user, vault, "A.md")

    # Same client id, new path — the rename/resurrect path keyed on a stable id
    # must still restore the row even within the window.
    assert {:ok, moved} =
             Notes.upsert_note(user, vault, %{
               "id" => note.id,
               "path" => "B.md",
               "content" => "# Body"
             })

    assert moved.id == note.id
    assert moved.path == "B.md"
  end
end
