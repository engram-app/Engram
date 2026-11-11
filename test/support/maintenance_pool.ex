defmodule Engram.Test.MaintenancePool do
  @moduledoc """
  Starts `Engram.Repo.Maintenance` the way prod runs it (docs/context/
  rls-enforcement-testing-traps.md, trap 9): a real second pool, connected
  as the `engram_maintenance` role (no SUPERUSER, no BYPASSRLS), with
  `:maintenance_repo_enabled` set, so `Repo.maintenance/0` and
  `TenantScan.pool/0` take the fleet path. Call from an `async: false`
  test's `setup`; ExUnit stops the pool and the flag is cleared on exit.

  Other options are repo config (`stacktrace: true` puts each query's
  stacktrace in its telemetry metadata).

  `role: :owner` keeps the test database's own login (a superuser, so RLS
  does not apply) for tests that predate the prod-role pool and assert
  something other than the role's grants. Prefer the default.

  The pool is a second connection: it cannot see sandbox rows. Fixtures it
  must read are committed (`Ecto.Adapters.SQL.Sandbox.unboxed_run/2`) and
  removed by the test.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 1, on_exit: 1]

  def start!(opts \\ []) do
    role =
      case Keyword.get(opts, :role, :maintenance) do
        :maintenance ->
          [
            after_connect:
              {Postgrex, :query!, ["SET SESSION AUTHORIZATION engram_maintenance", []]}
          ]

        :owner ->
          []
      end

    config =
      Keyword.merge(
        Engram.Repo.config(),
        [pool: DBConnection.ConnectionPool, pool_size: 1] ++ role ++ Keyword.delete(opts, :role)
      )

    start_supervised!({Engram.Repo.Maintenance, config})
    Application.put_env(:engram, :maintenance_repo_enabled, true)
    on_exit(fn -> Application.delete_env(:engram, :maintenance_repo_enabled) end)
    :ok
  end
end
