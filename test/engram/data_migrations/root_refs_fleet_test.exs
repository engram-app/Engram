defmodule Engram.DataMigrations.RootRefsFleetTest do
  @moduledoc """
  `RootRefs` on the fleet path (SaaS, prod and staging): discovery and the
  fill through the maintenance pool connected as the real
  `engram_maintenance` role (no SUPERUSER, no BYPASSRLS), root rows created
  on the app pool, two tenants in one pass. A missing grant or
  `maintenance_all` policy on `vaults`, `notes` or `folders` turns this red
  (docs/context/fleet-path-only-data-migration-bugs.md).

  Fixtures are COMMITTED (the pool is a second connection) and removed on exit.
  """
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Crypto
  alias Engram.DataMigrations.RootRefs
  alias Engram.Repo

  setup do
    Engram.Test.MaintenancePool.start!()

    jobs_before =
      Sandbox.unboxed_run(Repo, fn -> Repo.one(from(j in Oban.Job, select: max(j.id))) || 0 end)

    made =
      Sandbox.unboxed_run(Repo, fn ->
        for i <- 1..2 do
          {:ok, user} = Crypto.ensure_user_dek(insert(:user))
          insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
          {:ok, vault, _} = Engram.Vaults.register_vault(user, "Root#{i}", Ecto.UUID.generate())

          {:ok, note} =
            Engram.Notes.upsert_note(user, vault, %{"path" => "r#{i}.md", "content" => "x"},
              actor: "api"
            )

          # A previous-release write: no reference, no root row.
          Repo.query!("UPDATE notes SET folder_ref_id = NULL WHERE id = $1", [
            Ecto.UUID.dump!(note.id)
          ])

          Repo.query!("DELETE FROM folders WHERE id = $1", [Ecto.UUID.dump!(vault.id)])
          {user, vault, note}
        end
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        for {user, _, _} <- made do
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

  defp ref(note) do
    Sandbox.unboxed_run(Repo, fn ->
      %{rows: [[r]]} =
        Repo.query!("SELECT folder_ref_id FROM notes WHERE id = $1", [Ecto.UUID.dump!(note.id)])

      r && Ecto.UUID.load!(r)
    end)
  end

  test "a fleet pass creates every tenant's root row and fills its notes", %{made: made} do
    assert {:fleet, _} = Engram.Backfill.TenantScan.pool()

    assert {:more, more} = Sandbox.unboxed_run(Repo, fn -> RootRefs.run_pass() end)
    assert more[:rows] >= 2 and more[:blocked] == 0

    for {_, vault, note} <- made, do: assert(ref(note) == vault.id)

    # Nothing of these tenants is left (other tenants' committed rows may be).
    refute Enum.any?(made, fn {_, vault, note} -> ref(note) != vault.id end)
  end
end
