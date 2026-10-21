defmodule Engram.Workers.DailySnapshotMaintenanceTest do
  @moduledoc """
  Proves `DailySnapshot` reads every tenant through the maintenance pool.

  The app pool is dropped to `engram_app` with no tenant, where the vault and
  note policies hide every row, while a real maintenance pool runs on its own
  connection. Only a job that reads through that pool snapshots the vault.
  The rows are COMMITTED so the second connection sees them, and deleted on
  exit.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Engram.RlsCase

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Accounts.User
  alias Engram.Insights.UserDailyMetric
  alias Engram.Insights.VaultDailyMetric
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Repo.Maintenance
  alias Engram.Vaults.Vault
  alias Engram.Workers.DailySnapshot

  @email_prefix "daily-snapshot-maintenance-test-"

  setup do
    config = Keyword.merge(Repo.config(), pool: DBConnection.ConnectionPool, pool_size: 1)
    start_supervised!({Maintenance, config})
    Application.put_env(:engram, :maintenance_repo_enabled, true)
    on_exit(fn -> Application.delete_env(:engram, :maintenance_repo_enabled) end)

    delete_committed!()
    on_exit(&delete_committed!/0)

    {user, vault} =
      Sandbox.unboxed_run(Repo, fn ->
        user = insert(:user, email: "#{@email_prefix}#{System.unique_integer([:positive])}@t.co")
        vault = insert(:vault, user: user)
        insert(:note, user: user, vault: vault)
        {user, vault}
      end)

    %{user: user, vault: vault}
  end

  # Also at setup: a failing run whose job wrote through the sandbox holds
  # row locks its on_exit times out on, and leaves its user behind. The lock
  # timeout makes that a visible error instead of a hang.
  defp delete_committed! do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL lock_timeout = '5s'")
        ids = from(u in User, where: like(u.email, ^"#{@email_prefix}%"), select: u.id)
        # notes do not cascade from users; metrics cascade from users and vaults.
        Repo.delete_all(from(n in Note, where: n.user_id in subquery(ids)),
          skip_tenant_check: true
        )

        Repo.delete_all(from(v in Vault, where: v.user_id in subquery(ids)),
          skip_tenant_check: true
        )

        Repo.delete_all(ids, skip_tenant_check: true)
      end)
    end)
  end

  test "snapshots another tenant's vault through the maintenance pool", %{
    user: user,
    vault: vault
  } do
    # CONTROL: the app pool, as it runs here, cannot see the vault.
    assert {:returned, 0} =
             as_prod_role(fn -> Repo.aggregate(Vault, :count, skip_tenant_check: true) end)

    assert :ok = as_prod_role_committing(fn -> perform_job(DailySnapshot, %{}) end)

    assert [%VaultDailyMetric{notes: 1}] =
             Maintenance.all(from(m in VaultDailyMetric, where: m.vault_id == ^vault.id))

    assert [%UserDailyMetric{vault_count: 1, notes: 1}] =
             Maintenance.all(from(m in UserDailyMetric, where: m.user_id == ^user.id))
  end
end
