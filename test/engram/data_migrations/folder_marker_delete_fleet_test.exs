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
    # #2645's path-hash stop asks the real ledger, as in prod: while a vault
    # holds markers it writes their path hashes, which this delete matches.
    # (The test env pins `true`, a state a vault with markers never reaches.)
    Application.put_env(:engram, :path_hash_stop_markers_gone, Delete)
    on_exit(fn -> Application.put_env(:engram, :path_hash_stop_markers_gone, true) end)
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

  # #2678 review L2: a live marker whose `user_id` is not its vault owner's
  # (no constraint ties them) is skipped by the markers lock, which binds the
  # owners and is not widened. It stays, the ledger stays open, and the pass
  # says why: one warning per vault per day with the vault id and the count,
  # no paths. Fleet only: a per-tenant walk never sees another tenant's vault.
  test "a marker whose owner is not its vault's is kept, and warned about", %{
    made: [one, two] = made
  } do
    Engram.ServiceConfig.put_override(:marker_stop_floors, :assume)
    Engram.ServiceConfig.put_override(:folder_marker_stop, true)
    Engram.ServiceConfig.put_override(:marker_delete_floors, :assume)

    vault =
      Sandbox.unboxed_run(Repo, fn ->
        %{rows: [[marker, vault]]} =
          Repo.query!(
            "SELECT id, vault_id FROM notes WHERE user_id = $1 AND kind = 'folder' " <>
              "ORDER BY id LIMIT 1",
            [Ecto.UUID.dump!(one.id)]
          )

        Repo.query!("UPDATE notes SET user_id = $1 WHERE id = $2", [
          Ecto.UUID.dump!(two.id),
          marker
        ])

        Ecto.UUID.load!(vault)
      end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        for _ <- 1..2 do
          IdWindows.reset_walk(Delete.name())
          Delete.run_pass()
        end
      end)

    warnings = Regex.scan(~r/live markers whose owner is not the vault's, skipped/, log)
    assert length(warnings) == 1, log
    assert log =~ vault
    # Tenant one's own marker went; the foreign one (now counted under two)
    # stays beside two's unmatched vault.
    assert markers_by_user(made) == %{two.id => 3}
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

  # #2678 review: another tenant's explicit row at the unmatched marker's path
  # in tenant two's vault must not match it on the fleet path (the only path
  # that sees another tenant's rows). The probe's tenant check above its
  # fence keeps the vault unmatched, so the marker stays.
  test "a foreign explicit row at the marker's path does not match it", %{made: [one, two]} do
    Engram.ServiceConfig.put_override(:marker_stop_floors, :assume)
    Engram.ServiceConfig.put_override(:folder_marker_stop, true)
    Engram.ServiceConfig.put_override(:marker_delete_floors, :assume)
    t = Ecto.UUID.dump!(two.id)

    Sandbox.unboxed_run(Repo, fn ->
      %{rows: [[un, hmac]]} =
        Repo.query!(
          "SELECT id, full_path_hmac FROM folders WHERE user_id = $1 AND NOT explicit",
          [t]
        )

      %{rows: [[other, ohmac]]} =
        Repo.query!(
          "SELECT id, full_path_hmac FROM folders WHERE user_id = $1 AND explicit AND id <> $2",
          [t, un]
        )

      Repo.query!("UPDATE notes SET deleted_at = now() WHERE user_id = $1 AND folder_hmac = $2", [
        t,
        ohmac
      ])

      Repo.query!(
        "UPDATE folders SET user_id = $1, full_path_hmac = $2, explicit_seq = NULL WHERE id = $3",
        [Ecto.UUID.dump!(one.id), hmac, other]
      )
    end)

    for _ <- 1..2 do
      IdWindows.reset_walk(Delete.name())
      Delete.run_pass()
    end

    live =
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!(
          "SELECT count(*)::int FROM notes WHERE user_id = $1 AND kind = 'folder' AND deleted_at IS NULL",
          [t]
        ).rows
      end)

    assert live == [[1]]
  end
end
