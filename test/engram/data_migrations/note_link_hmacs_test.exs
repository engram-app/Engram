defmodule Engram.DataMigrations.NoteLinkHmacsTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query
  import Engram.Fixtures

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
end
