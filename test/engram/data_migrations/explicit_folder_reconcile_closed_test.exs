defmodule Engram.DataMigrations.ExplicitFolderReconcileClosedTest do
  @moduledoc """
  A closed `ExplicitFolderReconcile` ledger NEVER reopens (2639 re-review):
  after a rollback E -> D, a reopen would send listings to markers E never
  wrote. A ghost row in a vault another session holds is skipped (logged,
  retried the next day), the ledger stays done and listings stay on the flag.

  Fixtures are COMMITTED (the lock holder is a second connection) and removed
  on exit.
  """
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Backfill.IdWindows
  alias Engram.Crypto
  alias Engram.DataMigrations
  alias Engram.DataMigrations.ExplicitFolderReconcile, as: Reconcile
  alias Engram.{Notes, Repo}

  setup do
    IdWindows.reset_walk(Reconcile.name())

    {user, vault} =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, user} = Crypto.ensure_user_dek(insert(:user))
        {:ok, vault, _} = Engram.Vaults.register_vault(user, "Held", Ecto.UUID.generate())
        {:ok, %{folders: [%{id: m}]}} = Notes.create_folder_markers(user, vault, ["Ghost"])
        # 0.89.0's cascade marker leg: the marker gone, the flag kept.
        Repo.query!("UPDATE notes SET deleted_at = now() WHERE id = $1", [Ecto.UUID.dump!(m)])
        {user, vault}
      end)

    on_exit(fn ->
      DataMigrations.forget(Reconcile.name(), Reconcile.version())

      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("DELETE FROM notes WHERE user_id = $1", [Ecto.UUID.dump!(user.id)])
        Repo.query!("DELETE FROM folders WHERE user_id = $1", [Ecto.UUID.dump!(user.id)])

        Repo.delete_all(from(v in Engram.Vaults.Vault, where: v.user_id == ^user.id),
          skip_tenant_check: true
        )

        Repo.delete!(user, skip_tenant_check: true)
      end)
    end)

    %{user: user, vault: vault}
  end

  test "a closed ledger with a held ghost row stays done; listings stay on the flag", %{
    user: u,
    vault: v
  } do
    :ok = DataMigrations.mark_done(Reconcile.name(), Reconcile.version())

    # Another session holds the vault row FOR UPDATE (a writer mid-write), so
    # the walk's FOR SHARE SKIP LOCKED skips the vault.
    {:ok, holder} = Postgrex.start_link(Engram.Application.repo_connection_opts())
    test = self()

    locker =
      Task.async(fn ->
        Postgrex.transaction(holder, fn c ->
          Postgrex.query!(c, "SELECT 1 FROM vaults WHERE id = $1 FOR UPDATE", [
            Ecto.UUID.dump!(v.id)
          ])

          send(test, :locked)
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive :locked

    try do
      assert Reconcile.run_pass() == :done
      assert DataMigrations.completed_at(Reconcile.name(), Reconcile.version())
      assert {:ok, ["Ghost"]} = Notes.list_explicit_folders(u, v)
    after
      send(locker.pid, :release)
      Task.await(locker)
      GenServer.stop(holder)
    end
  end
end
