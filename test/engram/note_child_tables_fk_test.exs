defmodule Engram.NoteChildTablesFkTest do
  # crdt_update_log and note_revisions rows belong to a note, and their
  # note_id FK cascades. Their user_id / vault_id FKs only repeated it (note
  # to vault to user): each append paid two more FK checks and kept two more
  # indexes. They were dropped; the columns stay for RLS. These tests prove
  # the note cascade alone still removes the rows on every delete path.
  use Engram.DataCase, async: true

  alias Engram.Notes.CrdtUpdateLog
  alias Engram.Notes.Revision

  setup do
    user = insert(:user)
    vault = insert(:vault, user: user)
    note = insert(:note, user: user, vault: vault)

    Repo.insert!(
      %CrdtUpdateLog{
        note_id: note.id,
        user_id: user.id,
        vault_id: vault.id,
        update_ciphertext: "c",
        update_nonce: "n"
      },
      skip_tenant_check: true
    )

    Repo.insert!(
      %Revision{
        note_id: note.id,
        user_id: user.id,
        vault_id: vault.id,
        actor: "sync",
        origin: "edit",
        session_started_at: DateTime.utc_now()
      },
      skip_tenant_check: true
    )

    %{user: user, vault: vault, note: note}
  end

  defp count(schema, note),
    do:
      Repo.aggregate(from(r in schema, where: r.note_id == ^note.id), :count,
        skip_tenant_check: true
      )

  test "the redundant FKs and their indexes are gone; the RLS columns stay" do
    %{rows: fks} =
      Repo.query!("""
      SELECT conname FROM pg_constraint
      WHERE contype = 'f' AND conrelid IN ('crdt_update_log'::regclass, 'note_revisions'::regclass)
      """)

    assert fks |> List.flatten() |> Enum.reject(&String.contains?(&1, "note_id")) ==
             ["note_revisions_restored_from_id_fkey"]

    %{rows: idx} =
      Repo.query!("""
      SELECT indexname FROM pg_indexes WHERE tablename IN ('crdt_update_log', 'note_revisions')
      """)

    idx = List.flatten(idx)
    refute "crdt_update_log_user_id_index" in idx
    refute "note_revisions_user_id_index" in idx
    refute "note_revisions_vault_id_index" in idx
    # Kept: the sync quiescence endpoint counts a vault's pending updates.
    assert "crdt_update_log_vault_id_index" in idx
  end

  test "deleting the vault removes its notes' log and revision rows", ctx do
    Repo.delete!(ctx.vault, skip_tenant_check: true)
    assert count(CrdtUpdateLog, ctx.note) == 0
    assert count(Revision, ctx.note) == 0
  end

  # As Accounts.Lifecycle deletes an account: its vaults, then the user row
  # (notes.user_id does not cascade).
  test "deleting the account removes them too", ctx do
    Repo.with_tenant!(ctx.user.id, fn ->
      Repo.delete_all(from(v in Engram.Vaults.Vault, where: v.user_id == ^ctx.user.id))
      Repo.delete!(ctx.user, skip_tenant_check: true)
    end)

    assert count(CrdtUpdateLog, ctx.note) == 0
    assert count(Revision, ctx.note) == 0
  end
end
