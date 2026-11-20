defmodule Engram.DataMigrations.NoteFolderHashNullFleetTest do
  @moduledoc """
  `NoteFolderHashNull`'s fleet walk (SaaS, prod and staging): through the
  maintenance pool connected as the real `engram_maintenance` role (no
  SUPERUSER, no BYPASSRLS), across two tenants in one walk. The registry
  guard (`maintenance_pool_registry_test.exs`) never reaches this walk: the
  pass is blocked there because `note_payload_stamps` is open
  (docs/context/fleet-path-only-data-migration-bugs.md). A missing grant or
  `maintenance_all` policy on `notes` or `folders` turns this red.

  Fixtures are COMMITTED (the pool is a second connection) and removed on exit.
  """
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Backfill.IdWindows
  alias Engram.Crypto
  alias Engram.DataMigrations
  alias Engram.DataMigrations.NoteFolderHashNull, as: Null
  alias Engram.DataMigrations.NotePayloadStamps, as: Stamps
  alias Engram.Repo

  setup do
    Engram.Test.MaintenancePool.start!()
    IdWindows.reset_walk(Null.name())

    jobs_before =
      Sandbox.unboxed_run(Repo, fn -> Repo.one(from(j in Oban.Job, select: max(j.id))) || 0 end)

    made =
      Sandbox.unboxed_run(Repo, fn ->
        for i <- 1..2 do
          {:ok, user} = Crypto.ensure_user_dek(insert(:user))
          insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
          {:ok, vault, _} = Engram.Vaults.register_vault(user, "Hash#{i}", Ecto.UUID.generate())

          {:ok, note} =
            Engram.Notes.upsert_note(
              user,
              vault,
              %{"path" => "A/n#{i}.md", "content" => "# T\n\nbody"},
              actor: "api"
            )

          # Its folder row as a release before the S6 step 3 write stop left it.
          Repo.query!(
            "UPDATE folders f SET full_path_hmac = n.folder_hmac FROM notes n " <>
              "WHERE n.id = $1 AND f.id = n.folder_ref_id",
            [Ecto.UUID.dump!(note.id)]
          )

          {user, note}
        end
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        for {user, _} <- made do
          # Notes and folder rows first, so the vault delete runs no folder
          # RI action on a shared pool backend.
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

  defp hash_at(id) do
    Sandbox.unboxed_run(Repo, fn ->
      %{rows: [[h]]} =
        Repo.query!("SELECT folder_hmac FROM notes WHERE id = $1", [Ecto.UUID.dump!(id)])

      h
    end)
  end

  test "one fleet pass nulls every tenant's placed note hashes", %{made: made} do
    assert {:fleet, _} = Engram.Backfill.TenantScan.pool()
    for {_, n} <- made, do: assert(is_binary(hash_at(n.id)))

    :ok = DataMigrations.mark_done(Stamps.name(), Stamps.version())
    assert {:more, _} = Null.run_pass()

    assert Enum.map(made, fn {_, n} -> hash_at(n.id) end) == [nil, nil]
  end
end
