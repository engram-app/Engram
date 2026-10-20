defmodule Engram.InsightsMaintenanceTest do
  @moduledoc """
  Proves `Engram.Insights` reads other tenants through the maintenance pool.

  The app pool is dropped to `engram_app` with no tenant, where the vault
  policy hides every row, while a real maintenance pool runs on its own
  connection. Only a report that reads through that pool sees the vault.
  The rows are COMMITTED so the second connection sees them, and deleted on
  exit (and at setup, after a failed run).
  """
  use Engram.DataCase, async: false

  import Engram.RlsCase

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Accounts.User
  alias Engram.Insights
  alias Engram.Repo
  alias Engram.Repo.Maintenance
  alias Engram.Vaults.Vault

  @email_prefix "insights-maintenance-test-"

  setup do
    config = Keyword.merge(Repo.config(), pool: DBConnection.ConnectionPool, pool_size: 1)
    start_supervised!({Maintenance, config})
    Application.put_env(:engram, :maintenance_repo_enabled, true)
    on_exit(fn -> Application.delete_env(:engram, :maintenance_repo_enabled) end)

    delete_committed!()
    on_exit(&delete_committed!/0)

    Sandbox.unboxed_run(Repo, fn ->
      user = insert(:user, email: "#{@email_prefix}#{System.unique_integer([:positive])}@t.co")
      insert(:vault, user: user)
    end)

    :ok
  end

  defp delete_committed! do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL lock_timeout = '5s'")
        ids = from(u in User, where: like(u.email, ^"#{@email_prefix}%"), select: u.id)

        Repo.delete_all(from(v in Vault, where: v.user_id in subquery(ids)),
          skip_tenant_check: true
        )

        Repo.delete_all(ids, skip_tenant_check: true)
      end)
    end)
  end

  test "a report sees another tenant's vault through the maintenance pool" do
    # CONTROL: the app pool, as it runs here, cannot see the vault.
    assert {:returned, 0} =
             as_prod_role(fn -> Repo.aggregate(Vault, :count, skip_tenant_check: true) end)

    assert {:returned, %{steps: steps}} = as_prod_role(fn -> Insights.report("funnel", :all) end)
    assert Enum.find(steps, &(&1.step == "vault_created")).users >= 1
  end
end
