defmodule Engram.DataMigrations.FolderMarkerDeleteTest do
  # S6 step 4: once markers stop, the ledger deletes every marker whose
  # folder row carries the flag alone, never an unmatched one.
  use Engram.DataCase, async: false

  alias Engram.Backfill.IdWindows
  alias Engram.DataMigrations.{ExplicitFolderReconcile, FolderMarkerDelete}
  alias Engram.{FolderRows, Folders, Notes, QueryPlan, QueryRecorder, Repo}

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    Engram.ServiceConfig.put_override(:folder_marker_delete, true)
    IdWindows.reset_walk(FolderMarkerDelete.name())

    # `done?/0` caches true per node (persistent_term); the sandbox rolls the
    # ledger row back, so the cache must go too.
    on_exit(fn ->
      Engram.DataMigrations.forget(FolderMarkerDelete.name(), FolderMarkerDelete.version())
    end)

    %{user: user, vault: insert(:vault, user: user)}
  end

  # Markers are written with the stop off (the test default), then it goes on.
  # And the rollback floor at E (`FolderMarkerDelete.floors?/0`).
  defp stop_on! do
    Engram.ServiceConfig.put_override(:marker_stop_floors, :assume)
    Engram.ServiceConfig.put_override(:folder_marker_stop, true)
    Engram.ServiceConfig.put_override(:marker_delete_floors, :assume)
  end

  defp markers(vault, live \\ true) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM notes WHERE vault_id = $1 AND kind = 'folder' AND " <>
          if(live, do: "deleted_at IS NULL", else: "deleted_at IS NOT NULL"),
        [Ecto.UUID.dump!(vault.id)]
      )

    n
  end

  defp until_done(mod) do
    IdWindows.reset_walk(mod.name())

    Enum.reduce_while(1..5, nil, fn _, _ ->
      case mod.run_pass() do
        :done -> {:halt, :done}
        more -> {:cont, more}
      end
    end)
  end

  defp explicit(user, vault), do: elem(Notes.list_explicit_folders(user, vault), 1)

  test "deletes the markers; the folders stay listed and survive a reconcile", %{
    user: u,
    vault: v
  } do
    {:ok, _} = Folders.create_markers(u, v, ["A", "B/C"])
    stop_on!()

    assert until_done(FolderMarkerDelete) == :done
    assert markers(v) == 0
    assert explicit(u, v) == ["A", "B/C"]

    assert until_done(ExplicitFolderReconcile) == :done
    assert explicit(u, v) == ["A", "B/C"]
  end

  # The marker match is by path hash (`full_path_hmac = folder_hmac`), and
  # #2645 stops writing folder hashes once a vault's markers are gone. A
  # release that still writes markers (D, after a rollback) can put a marker
  # on an existing hashless row; `Rows.ensure` writes the marker's hash onto
  # that row (#2639), so the delete matches it.
  test "a marker on a hashless folder row takes its hash and is deleted", %{user: u, vault: v} do
    {:ok, _} = Notes.upsert_note(u, v, %{"path" => "H/n.md", "content" => "x"}, actor: "api")
    row = FolderRows.tree(u)["H"].id
    Repo.query!("UPDATE folders SET full_path_hmac = NULL WHERE id = $1", [Ecto.UUID.dump!(row)])

    # Markers still written (the stop off: release D's writer).
    {:ok, _} = Folders.create_markers(u, v, ["H"])

    assert [[row_hash, marker_hash]] =
             Repo.query!(
               "SELECT f.full_path_hmac, n.folder_hmac FROM folders f, notes n " <>
                 "WHERE f.id = $1 AND n.vault_id = f.vault_id AND n.kind = 'folder' " <>
                 "AND n.deleted_at IS NULL",
               [Ecto.UUID.dump!(row)]
             ).rows

    assert is_binary(marker_hash)
    assert row_hash == marker_hash

    stop_on!()
    assert until_done(FolderMarkerDelete) == :done
    assert markers(v) == 0
    assert explicit(u, v) == ["H"]
  end

  test "a vault with a live marker but no explicit row is not touched", %{user: u, vault: v} do
    {:ok, _} = Folders.create_markers(u, v, ["X", "Y"])

    Repo.query!("UPDATE folders SET explicit = false WHERE id = $1", [
      Ecto.UUID.dump!(FolderRows.tree(u)["X"].id)
    ])

    stop_on!()

    assert {:more, _} = FolderMarkerDelete.run_pass()
    assert markers(v) == 2
  end

  test "the undo of a delete made while markers were written still restores the folder", %{
    user: u,
    vault: v
  } do
    {:ok, _} = Folders.create_markers(u, v, ["T"])
    op = Ecto.UUID.generate()
    {:ok, _} = Folders.delete(u, v, "T", recursive: true, op_id: op)
    stop_on!()

    assert until_done(FolderMarkerDelete) == :done
    assert markers(v) == 0

    assert {:ok, _} = Folders.restore_op(u, v, op)
    assert explicit(u, v) == ["T"]
  end

  test "blocked while markers are still written", %{user: u, vault: v} do
    {:ok, _} = Folders.create_markers(u, v, ["Z"])
    assert FolderMarkerDelete.run_pass() == {:more, rows: 0, blocked: 1}
    assert markers(v) == 1
  end

  test "kill switch: off by default" do
    Engram.ServiceConfig.put_override(:folder_marker_delete, nil)
    refute FolderMarkerDelete.enabled?()
  end

  test "a trashed marker is left alone (trash history)", %{user: u, vault: v} do
    {:ok, _} = Folders.create_markers(u, v, ["Live", "Gone"])
    {:ok, _} = Folders.delete(u, v, "Gone", recursive: true, op_id: Ecto.UUID.generate())
    assert markers(v, false) == 1
    stop_on!()

    assert until_done(FolderMarkerDelete) == :done
    assert {markers(v), markers(v, false)} == {0, 1}
  end

  # #2652 review M1: a rollback to D (whose writers insert markers) and a roll
  # forward leave the closed ledger true with a marker present. `done?/2`
  # sees it at once; the daily re-verify walk finds and deletes it.
  test "after a rollback writes a marker, done?/2 is false and the re-walk clears it", ctx do
    %{user: u, vault: v} = ctx
    {:ok, _} = Folders.create_markers(u, v, ["A"])
    stop_on!()
    assert until_done(FolderMarkerDelete) == :done
    Engram.DataMigrations.mark_done(FolderMarkerDelete.name(), FolderMarkerDelete.version())
    assert Repo.with_tenant!(u.id, fn -> FolderMarkerDelete.done?(u.id, v.id) end)

    # Release D again (or the kill switch): the stop is off and a create
    # writes a marker.
    Engram.ServiceConfig.put_override(:folder_marker_stop, false)
    {:ok, _} = Folders.create_markers(u, v, ["D"])
    assert markers(v) == 1
    assert FolderMarkerDelete.done?()
    refute Repo.with_tenant!(u.id, fn -> FolderMarkerDelete.done?(u.id, v.id) end)

    # Forward to E: the re-verify walk deletes it.
    assert FolderMarkerDelete.reverify?()
    stop_on!()
    assert until_done(FolderMarkerDelete) == :done
    assert markers(v) == 0
    assert explicit(u, v) == ["A", "D"]
  end

  test "the folder_marker_delete_max_fixed override caps a pass", %{user: u, vault: v} do
    {:ok, _} = Folders.create_markers(u, v, ["O1", "O2", "O3"])
    stop_on!()
    Engram.ServiceConfig.put_override(:folder_marker_delete_max_fixed, 1)

    assert {:more, _} = FolderMarkerDelete.run_pass(batch: 1)
    assert markers(v) == 2
  end

  test "an invalid max_fixed override falls back to the default, with a warning", ctx do
    %{user: u, vault: v} = ctx
    {:ok, _} = Folders.create_markers(u, v, ["I1", "I2"])
    stop_on!()
    Engram.ServiceConfig.put_override(:folder_marker_delete_max_fixed, 0)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert until_done(FolderMarkerDelete) == :done
      end)

    assert markers(v) == 0
    assert log =~ "folder_marker_delete_max_fixed is not a positive integer"
  end

  test "an unmatched vault is warned about once a day, not once a pass", %{user: u, vault: v} do
    {:ok, _} = Folders.create_markers(u, v, ["W"])

    Repo.query!("UPDATE folders SET explicit = false WHERE id = $1", [
      Ecto.UUID.dump!(FolderRows.tree(u)["W"].id)
    ])

    stop_on!()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        for _ <- 1..2 do
          IdWindows.reset_walk(FolderMarkerDelete.name())
          FolderMarkerDelete.run_pass()
        end
      end)

    warnings = Regex.scan(~r/vault skipped, live markers without an explicit folder row/, log)
    assert length(warnings) == 1, log
    assert log =~ v.id
    assert markers(v) == 1
  end

  test "the per-pass cap stops the walk and the next pass resumes", %{user: u, vault: v} do
    {:ok, _} = Folders.create_markers(u, v, ["P1", "P2", "P3"])
    stop_on!()

    assert {:more, _} = FolderMarkerDelete.run_pass(max_fixed: 1, batch: 1)
    assert markers(v) == 2
    assert until_done(FolderMarkerDelete) == :done
    assert markers(v) == 0
  end

  # #2652 review L3: the window statements as engram_maintenance (the fleet
  # role) use the marker and folder path indexes.
  test "plans as engram_maintenance", %{user: u, vault: v} do
    # A realistic vault: many notes, some markers, real statistics (ANALYZE).
    # A live-notes range filtered on `kind` would read the whole vault per
    # window, O(vault) against the 5 s statement bound.
    for i <- 1..200 do
      {:ok, _} =
        Notes.upsert_note(u, v, %{"path" => "F#{rem(i, 20)}/n#{i}.md", "content" => "x"},
          actor: "api"
        )
    end

    for i <- 1..10, do: {:ok, _} = Folders.create_markers(u, v, ["M#{i}"])
    other = insert(:vault, user: u)
    for i <- 1..10, do: {:ok, _} = Folders.create_markers(u, other, ["O#{i}"])
    Repo.query!("ANALYZE notes")
    Repo.query!("ANALYZE folders")
    ids = [Ecto.UUID.dump!(v.id)]
    owners = [Ecto.UUID.dump!(u.id)]

    # As analyzed, and with the path hash costed as unselective (the shape
    # #2652's CI hit: the planner left `folders_full_path` for the explicit
    # partial index, and with only `vault_id` bound read it as a skip scan
    # over every tenant). Then with nested loops costed out: a planner that
    # prefers a hash join (seen once on a small folders table) must still
    # have nothing to hash, the folder probe staying one per marker.
    plans =
      for shape <- [:analyzed, :unselective_path_hash, :no_nestloop] do
        if shape == :unselective_path_hash do
          Repo.query!("ALTER TABLE folders ALTER COLUMN full_path_hmac SET (n_distinct = 1)")
          Repo.query!("ANALYZE folders")
        end

        if shape == :no_nestloop, do: Repo.query!("SET LOCAL enable_nestloop = off")

        QueryPlan.rls_plans(u.id, FolderMarkerDelete.unmatched_sql(), [ids, owners],
          role: "engram_maintenance"
        )
      end

    for unmatched <- plans, plan <- [unmatched.custom, unmatched.generic] do
      assert plan =~ "notes_user_vault_folder_marker", plan
      refute plan =~ "notes_user_vault_live", plan
      # The folder probe: by path hash or the vault's explicit rows, either
      # bound to the vault, never `folders_user` (#2652's CI after #2639
      # added `folders_explicit_user_vault`: a `vault_id`-only condition on
      # it was a skip scan over every tenant, so its conditions name both).
      QueryPlan.assert_scans_vault_bound!(plan)

      for [cond] <-
            Regex.scan(
              ~r/folders_explicit_user_vault on folders[^\n]*\n\s*Index Cond: ([^\n]*)/,
              plan,
              capture: :all_but_first
            ),
          do: assert(cond =~ "user_id =", cond <> "\n" <> plan)

      refute plan =~ "Seq Scan on notes", plan
    end
  end

  # #2652 re-review L1: the window's delete (stamp the folder rows, delete
  # the markers) planned as the fleet role, EXPLAIN only (it writes). Every
  # folders read vault-bound or a primary-key probe, notes by primary key,
  # with real statistics and with nested loops costed out (a planner that
  # would rather hash must have no tenant-wide side to hash).
  test "plans the delete as engram_maintenance", %{user: u, vault: v} do
    for i <- 1..10, do: {:ok, _} = Folders.create_markers(u, v, ["D#{i}"])

    for _ <- 1..5 do
      {:ok, other} = Engram.Fixtures.user_with_dek_fixture()
      ov = insert(:vault, user: other)
      for i <- 1..20, do: {:ok, _} = Folders.create_markers(other, ov, ["O#{i}"])
    end

    Repo.query!("ANALYZE notes")
    Repo.query!("ANALYZE folders")

    %{rows: ids} =
      Repo.query!("SELECT id FROM notes WHERE vault_id = $1 AND kind = 'folder'", [
        Ecto.UUID.dump!(v.id)
      ])

    params = [List.flatten(ids), [Ecto.UUID.dump!(v.id)]]

    for shape <- [:analyzed, :no_nestloop] do
      if shape == :no_nestloop, do: Repo.query!("SET LOCAL enable_nestloop = off")

      %{custom: custom, generic: generic} =
        QueryPlan.rls_plans(u.id, FolderMarkerDelete.delete_sql(), params,
          role: "engram_maintenance",
          analyze: false
        )

      for plan <- [custom, generic] do
        QueryPlan.assert_scans_vault_bound!(plan)
        assert plan =~ ~r/Scan using notes_pkey on notes/, plan
        refute plan =~ "Seq Scan on notes", plan

        refute plan =~ ~r/Index (Only )?Scan using notes_\w+ on notes n\s*\n(?!\s*Index Cond)/,
               plan
      end
    end
  end

  # done?/2's per-vault probe runs on every folder op (PathHashStop): planned
  # as the app role under RLS and as the fleet role, it must be one probe of
  # the marker index, never a scan.
  # The shape it runs against once the ledger is done: a vault of notes and
  # no marker, where a live-notes range filtered on `kind` would read the
  # whole vault on every folder op. Real statistics (ANALYZE), as prod has.
  test "plans: done?/2's probe is the marker index under RLS", %{user: u, vault: v} do
    for i <- 1..200 do
      {:ok, _} =
        Notes.upsert_note(u, v, %{"path" => "F#{rem(i, 20)}/n#{i}.md", "content" => "x"},
          actor: "api"
        )
    end

    {:ok, _} = Folders.create_markers(u, insert(:vault, user: u), ["Elsewhere"])
    Repo.query!("ANALYZE notes")
    Engram.DataMigrations.mark_done(FolderMarkerDelete.name(), FolderMarkerDelete.version())

    {_, queries} =
      QueryRecorder.record(fn ->
        Repo.with_tenant!(u.id, fn -> FolderMarkerDelete.done?(u.id, v.id) end)
      end)

    me = self()

    [{sql, params}] =
      for %{sql: q, params: p, pid: ^me} <- queries,
          q =~ ~s(FROM "notes") and q =~ "folder",
          do: {q, p}

    for role <- ["engram_app", "engram_maintenance"] do
      %{custom: custom, generic: generic} = QueryPlan.rls_plans(u.id, sql, params, role: role)

      for plan <- [custom, generic] do
        assert plan =~ "notes_user_vault_folder_marker", plan
        refute plan =~ "Seq Scan on notes", plan
      end
    end
  end

  # #2652 re-review: the delete is irreversible, so it also needs the rollback
  # floor at E (no rollback target reads markers), not just the stop on.
  test "blocked while the rollback floor is below E, even with markers stopped", ctx do
    %{user: _u, vault: v} = ctx
    {:ok, _} = Folders.create_markers(ctx.user, v, ["Fl"])
    Engram.ServiceConfig.put_override(:marker_stop_floors, :assume)
    refute FolderMarkerDelete.floors?(:enforce)

    assert FolderMarkerDelete.run_pass() == {:more, rows: 0, blocked: 1}
    assert markers(v) == 1
  end
end
