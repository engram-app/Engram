defmodule Engram.DataMigrations.ExplicitFolderReconcileFleetTest do
  @moduledoc """
  `ExplicitFolderReconcile`'s fleet walk (SaaS, prod and staging): through
  the maintenance pool connected as the real `engram_maintenance` role (no
  SUPERUSER, no BYPASSRLS), across two tenants in one walk, with real folder
  rows so the vault `FOR SHARE` and the `folders` update run on that pool
  (#2639 re-review, M-B; docs/context/fleet-path-only-data-migration-bugs.md).
  A missing grant or `maintenance_all` policy on `vaults`, `folders` or
  `notes` turns this red.

  Fixtures are COMMITTED (the pool is a second connection) and removed on exit.
  """
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Backfill.IdWindows
  alias Engram.Crypto
  alias Engram.DataMigrations.ExplicitFolderReconcile, as: Reconcile
  alias Engram.Notes
  alias Engram.Repo

  setup do
    # Markers are written here, so the vault keeps release D's path hashes:
    # #2645's write stop is on only once a vault has no marker
    # (`PathHashStop.markers_gone?/2`), and the test env assumes it on.
    Application.put_env(:engram, :path_hash_stop_markers_gone, false)
    on_exit(fn -> Application.put_env(:engram, :path_hash_stop_markers_gone, true) end)
    Engram.Test.MaintenancePool.start!()
    IdWindows.reset_walk(Reconcile.name())

    jobs_before =
      Sandbox.unboxed_run(Repo, fn -> Repo.one(from(j in Oban.Job, select: max(j.id))) || 0 end)

    made =
      Sandbox.unboxed_run(Repo, fn ->
        for i <- 1..2 do
          {:ok, user} = Crypto.ensure_user_dek(insert(:user))
          insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
          {:ok, vault, _} = Engram.Vaults.register_vault(user, "Rec#{i}", Ecto.UUID.generate())
          {:ok, %{folders: [%{id: stale}]}} = Notes.create_folder_markers(user, vault, ["S#{i}"])
          {:ok, _} = Notes.create_folder_markers(user, vault, ["K#{i}"])

          # A pre-#2639 cascade's leftover: the marker gone, the flag kept.
          Repo.query!("UPDATE notes SET deleted_at = now() WHERE id = $1", [
            Ecto.UUID.dump!(stale)
          ])

          user
        end
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        for user <- made do
          Repo.query!("DELETE FROM notes WHERE user_id = $1", [Ecto.UUID.dump!(user.id)])
          Repo.query!("DELETE FROM folders WHERE user_id = $1", [Ecto.UUID.dump!(user.id)])

          Repo.delete_all(from(v in Engram.Vaults.Vault, where: v.user_id == ^user.id),
            skip_tenant_check: true
          )

          Repo.delete!(user, skip_tenant_check: true)
        end

        Repo.delete_all(from(j in Oban.Job, where: j.id > ^jobs_before))
      end)
    end)

    %{made: made}
  end

  defp explicit_by_user(made) do
    Sandbox.unboxed_run(Repo, fn ->
      %{rows: rows} =
        Repo.query!(
          "SELECT user_id, count(*) FILTER (WHERE explicit)::int FROM folders " <>
            "WHERE user_id = ANY($1) GROUP BY user_id",
          [Enum.map(made, &Ecto.UUID.dump!(&1.id))]
        )

      Map.new(rows, fn [u, n] -> {Ecto.UUID.load!(u), n} end)
    end)
  end

  test "one fleet pass clears every tenant's stale flag and keeps the marked ones",
       %{made: made} do
    assert {:fleet, _} = Engram.Backfill.TenantScan.pool()
    assert explicit_by_user(made) == Map.new(made, &{&1.id, 2})

    assert {:more, _} = Reconcile.run_pass()

    assert explicit_by_user(made) == Map.new(made, &{&1.id, 1})
  end
end
