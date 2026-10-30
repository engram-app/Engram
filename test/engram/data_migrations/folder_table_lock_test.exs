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

  import Ecto.Query, only: [from: 2]
  import Engram.Factory

  alias Engram.CheckpointInterleave
  alias Engram.DataMigrations.FolderTable
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
    # The previous release's write (the app's own writers create the folder row).
    note = Engram.Fixtures.insert_note!(user, vault, %{path: "Dir/l.md", content: "x"})

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

  # #2339: `delete_account` deletes the user's vaults, then the user row.
  # FolderTable's chunk transaction held the user row FOR SHARE (the rotation
  # gate) and then wanted the vault row (the folders FK): opposite orders, and
  # Postgres killed the delete. The backfill now takes the vault rows first,
  # NOWAIT, so a user under deletion is deferred and the delete never waits.
  test "a pass never deadlocks with an account delete, and defers that user", %{
    user: user,
    vault: vault
  } do
    note = Engram.Fixtures.insert_note!(user, vault, %{path: "Dir/d.md", content: "x"})

    # Back to what the previous release left: no folder row, no ref.
    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.query!("UPDATE notes SET folder_ref_id = NULL WHERE user_id = $1", [
          Ecto.UUID.dump!(user.id)
        ])

        Repo.query!("DELETE FROM folders WHERE user_id = $1", [Ecto.UUID.dump!(user.id)])
      end)

    test = self()

    deleter =
      Task.async(fn ->
        CheckpointInterleave.checkout_real!()

        Repo.with_tenant(user.id, fn ->
          # The first half of Lifecycle.hard_delete's transaction.
          Repo.delete_all(from(v in Engram.Vaults.Vault, where: v.user_id == ^user.id))
          send(test, :vaults_deleted)

          receive do
            :continue -> :ok
          after
            15_000 -> Repo.rollback(:test_timeout)
          end

          # The second half: the user row.
          Repo.delete_all(from(u in Engram.Accounts.User, where: u.id == ^user.id),
            skip_tenant_check: true
          )
        end)
      end)

    assert_receive :vaults_deleted, 5_000

    pass =
      Task.async(fn ->
        CheckpointInterleave.checkout_real!()
        FolderTable.run_pass(user_ids: [user.id])
      end)

    # The pass must not wait on the delete's vault rows (an unfixed one holds
    # the user row and blocks there, which deadlocks once the delete goes on).
    assert {:ok, {:more, stats}} = Task.yield(pass, 3_000) || Task.shutdown(pass, :brutal_kill)
    assert stats[:blocked] >= 1

    send(deleter.pid, :continue)
    assert {:ok, _} = Task.await(deleter, 15_000)
    assert note.id
  end
end
