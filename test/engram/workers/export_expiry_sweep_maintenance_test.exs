defmodule Engram.Workers.ExportExpirySweepMaintenanceTest do
  @moduledoc """
  Proves `ExportExpirySweep` runs on the maintenance pool, not on `Repo`.

  The other sweep tests cannot: the suite connects as a superuser and never
  starts `Engram.Repo.Maintenance`, so `Repo.maintenance()` IS `Repo` and a
  sweep that quietly moved back onto `Repo` passes them all.

  Here the app pool is dropped to `engram_app` with no tenant, where the
  tenant policy hides every export row, while a real maintenance pool runs on
  its own superuser connection. Only a sweep that reads and writes through
  that pool can expire the row.

  The row has to be COMMITTED for the second connection to see it, so this
  file inserts outside the sandbox and deletes what it made on exit.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Engram.RlsCase

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Accounts.Export.Schema
  alias Engram.Repo
  alias Engram.Repo.Maintenance
  alias Engram.Storage.InMemory
  alias Engram.Workers.ExportExpirySweep

  setup do
    config = Keyword.merge(Repo.config(), pool: DBConnection.ConnectionPool, pool_size: 1)
    start_supervised!({Maintenance, config})

    Application.put_env(:engram, :maintenance_repo_enabled, true)
    on_exit(fn -> Application.delete_env(:engram, :maintenance_repo_enabled) end)

    InMemory.ensure_table()
    key = "exports/maintenance-sweep-#{System.unique_integer([:positive])}.zip"
    :ok = InMemory.put(key, "zip-bytes")

    user =
      Sandbox.unboxed_run(Repo, fn ->
        user = insert(:user)

        %Schema{}
        |> Schema.changeset(%{
          user_id: user.id,
          status: :ready,
          reason: :user_request,
          s3_keys: [%{"key" => key}],
          expires_at: DateTime.add(DateTime.utc_now(), -1, :hour)
        })
        |> Repo.insert!(skip_tenant_check: true)

        user
      end)

    # Cascades to the export row.
    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn -> Repo.delete!(user, skip_tenant_check: true) end)
    end)

    %{user: user, key: key}
  end

  test "expires the row and deletes the blob through the maintenance pool", %{
    user: user,
    key: key
  } do
    # CONTROL: the app pool, as it runs here, cannot see the row at all.
    assert {:returned, 0} =
             as_prod_role(fn ->
               Repo.aggregate(Schema, :count, skip_tenant_check: true)
             end)

    assert :ok = as_prod_role_committing(fn -> perform_job(ExportExpirySweep, %{}) end)

    [export] = Maintenance.all(from(e in Schema, where: e.user_id == ^user.id))
    assert export.status == :expired
    assert export.s3_keys == []
    refute InMemory.exists?(key)
  end
end
