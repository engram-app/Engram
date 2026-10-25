defmodule Engram.Workers.AttachmentBlobGCMaintenanceTest do
  @moduledoc """
  Proves `AttachmentBlobGC`'s claim (vault lock, tombstone lock, re-check,
  claim stamp, finalize) runs on the maintenance pool, not on `Repo`.

  The app pool is dropped to `engram_app` with no tenant, where the policy
  hides every vault and attachment row, while a real maintenance pool runs
  on its own connection. Only a sweep that locks, reads and writes through
  that pool can reap the blob. The pattern is
  `ExportExpirySweepMaintenanceTest` (docs/context/rls-enforcement-testing-traps.md,
  trap 9). Limit: the harness's maintenance pool connects with the suite's
  superuser config, not as the `engram_maintenance` role, so this proves the
  pool routing, not that role's grants (release.ex grants it UPDATE on every
  table, which `FOR NO KEY UPDATE` on vaults needs).

  The rows have to be COMMITTED for the second connection to see them, so
  this file inserts outside the sandbox and deletes what it made on exit.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Engram.RlsCase

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Attachments.Attachment
  alias Engram.Repo
  alias Engram.Repo.Maintenance
  alias Engram.Storage.InMemory
  alias Engram.Workers.AttachmentBlobGC

  setup do
    config = Keyword.merge(Repo.config(), pool: DBConnection.ConnectionPool, pool_size: 1)
    start_supervised!({Maintenance, config})

    Application.put_env(:engram, :maintenance_repo_enabled, true)
    on_exit(fn -> Application.delete_env(:engram, :maintenance_repo_enabled) end)

    InMemory.ensure_table()

    {user, att} =
      Sandbox.unboxed_run(Repo, fn ->
        user = insert(:user)
        vault = insert(:vault, user: user)
        key = "#{user.id}/#{vault.id}/objects/#{Ecto.UUID.generate()}"
        :ok = InMemory.put(key, "sealed")

        att =
          insert(:attachment,
            user: user,
            vault: vault,
            storage_key: key,
            deleted_at: DateTime.add(DateTime.utc_now(:second), -31, :day)
          )

        {user, att}
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        uid = Ecto.UUID.dump!(user.id)
        Repo.query!("DELETE FROM attachments WHERE user_id = $1", [uid])
        Repo.query!("DELETE FROM vaults WHERE user_id = $1", [uid])
        Repo.query!("DELETE FROM users WHERE id = $1", [uid])
      end)
    end)

    %{att: att}
  end

  test "claims and reaps through the maintenance pool", %{att: att} do
    # CONTROL: the app pool, as it runs here, cannot see the row at all.
    assert {:returned, 0} =
             as_prod_role(fn -> Repo.aggregate(Attachment, :count, skip_tenant_check: true) end)

    assert :ok = as_prod_role_committing(fn -> perform_job(AttachmentBlobGC, %{}) end)

    assert %{storage_key: nil, blob_gc_claimed_at: nil} = Maintenance.get!(Attachment, att.id)
    refute InMemory.exists?(att.storage_key)
  end
end
