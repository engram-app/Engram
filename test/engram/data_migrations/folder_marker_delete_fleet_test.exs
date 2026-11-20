defmodule Engram.DataMigrations.FolderMarkerDeleteFleetTest do
  @moduledoc """
  `FolderMarkerDelete`'s fleet walk (SaaS, prod and staging): through the
  maintenance pool connected as the real `engram_maintenance` role (no
  SUPERUSER, no BYPASSRLS), across two tenants in one walk, with real markers
  and folder rows, so the vault `FOR SHARE`, the unmatched check, both
  `folders` stamps and the `notes` delete run on that pool
  (docs/context/fleet-path-only-data-migration-bugs.md). Tenant 2 holds an
  unmatched marker: its vault is left whole.

  Fixtures are COMMITTED (the pool is a second connection) and removed on exit.
  """
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Backfill.IdWindows
  alias Engram.Crypto
  alias Engram.DataMigrations.FolderMarkerDelete, as: Delete
  alias Engram.Notes
  alias Engram.Repo

  setup do
    Engram.Test.MaintenancePool.start!()
    IdWindows.reset_walk(Delete.name())
    Engram.ServiceConfig.put_override(:folder_marker_delete, true)

    jobs_before =
      Sandbox.unboxed_run(Repo, fn -> Repo.one(from(j in Oban.Job, select: max(j.id))) || 0 end)

    made =
      Sandbox.unboxed_run(Repo, fn ->
        for i <- 1..2 do
          {:ok, user} = Crypto.ensure_user_dek(insert(:user))
          insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
          {:ok, vault, _} = Engram.Vaults.register_vault(user, "Rec#{i}", Ecto.UUID.generate())
          {:ok, _} = Notes.create_folder_markers(user, vault, ["S#{i}", "K#{i}"])

          # Tenant 2: one marker whose row lost its flag (unmatched).
          if i == 2,
            do:
              Repo.query!(
                "UPDATE folders SET explicit = false WHERE user_id = $1 AND explicit " <>
                  "AND id = (SELECT min(id::text)::uuid FROM folders WHERE user_id = $1)",
                [Ecto.UUID.dump!(user.id)]
              )

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

  defp markers_by_user(made) do
    Sandbox.unboxed_run(Repo, fn ->
      %{rows: rows} =
        Repo.query!(
          "SELECT user_id, count(*)::int FROM notes WHERE kind = 'folder' AND user_id = ANY($1) " <>
            "GROUP BY user_id",
          [Enum.map(made, &Ecto.UUID.dump!(&1.id))]
        )

      Map.new(rows, fn [u, n] -> {Ecto.UUID.load!(u), n} end)
    end)
  end

  test "one fleet pass deletes the matched tenant's markers and leaves the unmatched vault", %{
    made: [one, two] = made
  } do
    assert {:fleet, _} = Engram.Backfill.TenantScan.pool()
    Engram.ServiceConfig.put_override(:marker_stop_floors, :assume)
    Engram.ServiceConfig.put_override(:folder_marker_stop, true)
    Engram.ServiceConfig.put_override(:marker_delete_floors, :assume)
    assert markers_by_user(made) == %{one.id => 2, two.id => 2}

    assert {:more, _} = Delete.run_pass()

    assert markers_by_user(made) == %{two.id => 2}
  end

  # The stamp's ids come from the statement's snapshot. A writer that stamps
  # the row and commits while the stamp waits on its lock leaves a newer
  # version, which Postgres re-checks against the UPDATE's own WHERE only.
  # Red without the outer `explicit_seq IS NULL`: the row went to 0.
  test "a row stamped while the stamp waits on it keeps its seq", %{made: [one | _]} do
    Engram.ServiceConfig.put_override(:marker_stop_floors, :assume)
    Engram.ServiceConfig.put_override(:folder_marker_stop, true)
    Engram.ServiceConfig.put_override(:marker_delete_floors, :assume)

    row =
      Sandbox.unboxed_run(Repo, fn ->
        %{rows: [[id]]} =
          Repo.query!(
            "SELECT min(id::text)::uuid FROM folders WHERE user_id = $1 AND explicit",
            [Ecto.UUID.dump!(one.id)]
          )

        id
      end)

    me = self()

    writer =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Repo.query!("UPDATE folders SET explicit_seq = 9 WHERE id = $1", [row])
            send(me, :locked)

            # Commit only once the stamp is waiting on this row's lock.
            Enum.find(1..150, fn _ ->
              Process.sleep(10)
              %{rows: [[n]]} =
                Repo.query!(
                  "SELECT count(*)::int FROM pg_stat_activity " <>
                    "WHERE datname = current_database() AND wait_event_type = 'Lock'"
                )

              n > 0
            end)
          end)
        end)
      end)

    assert_receive :locked, 2_000
    assert {:more, _} = Delete.run_pass()
    assert {:ok, waited} = Task.await(writer, 5_000)
    assert waited, "the stamp never waited on the writer's lock"

    assert Sandbox.unboxed_run(Repo, fn ->
             Repo.query!("SELECT explicit_seq FROM folders WHERE id = $1", [row]).rows
           end) == [[9]]
  end
end
