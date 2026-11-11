defmodule Engram.Test.MaintenancePool do
  @moduledoc """
  Starts `Engram.Repo.Maintenance` the way prod runs it (docs/context/
  rls-enforcement-testing-traps.md, trap 9): a real second pool, connected
  as the `engram_maintenance` role (no SUPERUSER, no BYPASSRLS), with
  `:maintenance_repo_enabled` set, so `Repo.maintenance/0` and
  `TenantScan.pool/0` take the fleet path. Call from an `async: false`
  test's `setup`; ExUnit stops the pool and the flag is cleared on exit.

  The pool is a second connection: it cannot see sandbox rows. Fixtures it
  must read are committed (`Ecto.Adapters.SQL.Sandbox.unboxed_run/2`) and
  removed by the test.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 1, on_exit: 1]

  def start! do
    config =
      Keyword.merge(Engram.Repo.config(),
        pool: DBConnection.ConnectionPool,
        pool_size: 1,
        after_connect: {Postgrex, :query!, ["SET SESSION AUTHORIZATION engram_maintenance", []]}
      )

    start_supervised!({Engram.Repo.Maintenance, config})
    Application.put_env(:engram, :maintenance_repo_enabled, true)
    on_exit(fn -> Application.delete_env(:engram, :maintenance_repo_enabled) end)
    :ok
  end
end
