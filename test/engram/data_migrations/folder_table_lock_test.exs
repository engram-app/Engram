defmodule Engram.DataMigrations.FolderTableLockTest do
  @moduledoc """
  FolderTable's SKIP LOCKED path, on REAL connections (see
  `Engram.CheckpointInterleave`): in the sandbox every process shares one
  connection, so a row lock never blocks and SKIP LOCKED never skips.

  A pass that skipped a note a writer held pointed nothing at its folder, but
  the note still needs it. Reporting `:done` there would close the ledger
  over an unresolved row.
  """
  use ExUnit.Case, async: false

  import Engram.Factory

  alias Engram.CheckpointInterleave
  alias Engram.DataMigrations.FolderTable
  alias Engram.Notes
  alias Engram.Repo

  setup do
    CheckpointInterleave.checkout_real!()

    user_id = Ecto.UUID.generate()
    on_exit(fn -> CheckpointInterleave.cleanup(user_id) end)

    user =
      insert(:user,
        id: user_id,
        email: "folder-lock-#{System.unique_integer([:positive])}@test.com"
      )

    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "FolderLock", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  defp ref(user, id) do
    {:ok, %{rows: [[ref]]}} =
      Repo.with_tenant(user.id, fn ->
        Repo.query!("SELECT folder_ref_id FROM notes WHERE id = $1", [Ecto.UUID.dump!(id)])
      end)

    ref
  end

  test "a note a writer holds keeps the pass open and is taken once released", %{
    user: user,
    vault: vault
  } do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "Dir/l.md", "content" => "x"}, actor: "api")

    test = self()

    holder =
      Task.async(fn ->
        CheckpointInterleave.checkout_real!()

        Repo.with_tenant(user.id, fn ->
          Repo.query!("SELECT id FROM notes WHERE id = $1 FOR UPDATE", [Ecto.UUID.dump!(note.id)])
          send(test, :locked)

          receive do
            :release -> :ok
          after
            15_000 -> Repo.rollback(:test_timeout)
          end
        end)
      end)

    assert_receive :locked, 5_000

    # The folder row is created, the held note skipped: never `:done`.
    refute FolderTable.run_pass(user_ids: [user.id]) == :done
    refute FolderTable.run_pass(user_ids: [user.id]) == :done
    assert ref(user, note.id) == nil

    send(holder.pid, :release)
    Task.await(holder)

    assert {:more, _} = FolderTable.run_pass(user_ids: [user.id])
    assert ref(user, note.id) != nil
    assert :done = FolderTable.run_pass(user_ids: [user.id])
  end
end
