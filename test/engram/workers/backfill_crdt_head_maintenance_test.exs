defmodule Engram.Workers.BackfillCrdtHeadMaintenanceTest do
  @moduledoc """
  `BackfillCrdtHead.enqueue_all/0` (hourly, via WarmCrdtHeads) discovers work
  in ONE statement on `note_bodies` plus ONE primary-key probe of `notes` on
  the maintenance pool when one is configured, instead of one tenant
  transaction per user (2026-10-20 audit, P1-7). The candidates come from a
  `note_bodies` primary-key window and the notes written since the last run
  (no index on the head: it would end HOT body writes, NoteBodyReadTest).

  Same rig as ReconcileEmbeddingsMaintenanceTest: the app pool runs as
  `engram_app` with no tenant, where the notes policy hides every row, and a
  real maintenance pool runs on its own connection. Only discovery through
  that pool finds the notes. Rows are COMMITTED and deleted on exit.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query
  import Engram.RlsCase

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Notes.Note
  alias Engram.QueryRecorder
  alias Engram.Repo
  alias Engram.Repo.Maintenance
  alias Engram.Workers.BackfillCrdtHead

  @email_prefix "crdt-head-maintenance-test-"

  describe "on the maintenance pool" do
    setup do
      config = Keyword.merge(Repo.config(), pool: DBConnection.ConnectionPool, pool_size: 1)
      start_supervised!({Maintenance, config})
      Application.put_env(:engram, :maintenance_repo_enabled, true)
      on_exit(fn -> Application.delete_env(:engram, :maintenance_repo_enabled) end)

      delete_committed!()
      on_exit(&delete_committed!/0)

      vaults =
        Sandbox.unboxed_run(Repo, fn ->
          for i <- 1..2 do
            email = "#{@email_prefix}#{i}-#{System.unique_integer([:positive])}@t.co"
            user = insert(:user, email: email)
            vault = insert(:vault, user: user)
            note = insert(:note, user: user, vault: vault, crdt_head: nil)
            # The factory inserts no body row (nothing copies one any more),
            # and discovery reads `note_bodies`.
            Engram.Fixtures.mirror_body!(note.id)
            {user.id, vault.id}
          end
        end)

      %{vaults: vaults}
    end

    test "finds every tenant's vaults in one walk, none on the app pool", %{vaults: vaults} do
      test_pid = self()
      handler = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler,
        [:engram, :repo, :query],
        # By the SQL, not only `source`: a window read through
        # `IdWindows.by_id/2` has a subquery source (nil).
        fn _e, _m, %{source: source, query: sql, repo: repo}, _c ->
          cond do
            self() != test_pid or not (source == "notes" or sql =~ ~s("notes")) -> :ok
            repo == Repo -> send(test_pid, :app_pool_notes_query)
            true -> send(test_pid, :maintenance_notes_query)
          end
        end,
        nil
      )

      {_, queries} =
        try do
          QueryRecorder.record(fn ->
            assert as_prod_role_committing(fn -> BackfillCrdtHead.enqueue_all() end) >= 2
          end)
        after
          :telemetry.detach(handler)
        end

      refute_received :app_pool_notes_query

      # One probe of notes for both users' candidates (the old id-window walk
      # was 3 statements and read the whole table; a walk per user, 6). The
      # change feed's first run reads only vaults.
      assert drain(:maintenance_notes_query, 0) == 1
      assert QueryRecorder.unwindowed(queries, "notes", 1_000) == []

      for {user_id, vault_id} <- vaults do
        assert_enqueued(
          worker: BackfillCrdtHead,
          args: %{"user_id" => user_id, "vault_id" => vault_id}
        )
      end
    end
  end

  defp drain(msg, n) do
    receive do
      ^msg -> drain(msg, n + 1)
    after
      0 -> n
    end
  end

  defp delete_committed! do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL lock_timeout = '5s'")

        ids =
          from(u in Engram.Accounts.User,
            where: like(u.email, ^"#{@email_prefix}%"),
            select: u.id
          )

        Repo.delete_all(from(n in Note, where: n.user_id in subquery(ids)),
          skip_tenant_check: true
        )

        Repo.delete_all(from(v in Engram.Vaults.Vault, where: v.user_id in subquery(ids)),
          skip_tenant_check: true
        )

        Repo.delete_all(ids |> exclude(:select), skip_tenant_check: true)
      end)
    end)
  end
end
