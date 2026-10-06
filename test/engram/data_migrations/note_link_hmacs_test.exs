defmodule Engram.DataMigrations.NoteLinkHmacsTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query
  import Engram.Fixtures

  alias Engram.Attachments.Attachment
  alias Engram.Crypto
  alias Engram.DataMigrations.NoteLinkHmacs
  alias Engram.Notes.Note
  alias Engram.Workers.BackfillNoteLinks

  setup do
    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "DM", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  test "every note has a basename_hmac: done", %{user: user, vault: vault} do
    insert_note!(user, vault, %{path: "A.md", content: "x"})
    assert NoteLinkHmacs.run_pass() == :done
    refute_enqueued(worker: BackfillNoteLinks)
  end

  test "a note missing basename_hmac enqueues the chain and stays open", %{
    user: user,
    vault: vault
  } do
    note = insert_note!(user, vault, %{path: "A.md", content: "x"})

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        from(n in Note, where: n.id == ^note.id) |> Repo.update_all(set: [basename_hmac: nil])
      end)

    assert NoteLinkHmacs.run_pass() == :more
    assert_enqueued(worker: BackfillNoteLinks)
    assert NoteLinkHmacs.run_pass() == :more
    assert length(all_enqueued(worker: BackfillNoteLinks)) == 1
  end

  # The worker discards a soft-deleted vault's jobs, so its rows can never be
  # stamped: counting them would hold the migration open forever.
  test "a gap in a soft-deleted vault neither keeps it open nor enqueues", %{
    user: user,
    vault: vault
  } do
    note = insert_note!(user, vault, %{path: "A.md", content: "x"})
    clear_note_hmac(user, note)
    {:ok, _} = Engram.Vaults.delete_vault(user, vault.id)

    assert NoteLinkHmacs.run_pass() == :done
    refute_enqueued(worker: BackfillNoteLinks)
  end

  test "an attachment-only gap keeps it open and enqueues that pair", %{
    user: user,
    vault: vault
  } do
    insert_note!(user, vault, %{path: "A.md", content: "x"})
    att = insert_attachment!(user, vault, %{path: "a.png"})

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        from(a in Attachment, where: a.id == ^att.id)
        |> Repo.update_all(set: [basename_hmac: nil])
      end)

    assert NoteLinkHmacs.run_pass() == :more

    assert_enqueued(
      worker: BackfillNoteLinks,
      args: %{"user_id" => user.id, "vault_id" => vault.id}
    )
  end

  test "only pairs with a gap are enqueued", %{user: user, vault: vault} do
    {:ok, clean, _} = Engram.Vaults.register_vault(user, "Clean", Ecto.UUID.generate())
    insert_note!(user, clean, %{path: "B.md", content: "y"})
    note = insert_note!(user, vault, %{path: "A.md", content: "x"})
    clear_note_hmac(user, note)

    assert NoteLinkHmacs.run_pass() == :more
    assert [%{args: %{"vault_id" => vault_id}}] = all_enqueued(worker: BackfillNoteLinks)
    assert vault_id == vault.id
  end

  defp clear_note_hmac(user, note) do
    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        from(n in Note, where: n.id == ^note.id) |> Repo.update_all(set: [basename_hmac: nil])
      end)
  end
end
