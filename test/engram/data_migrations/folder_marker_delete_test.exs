defmodule Engram.DataMigrations.FolderMarkerDeleteTest do
  # S6 step 4: once markers stop, the ledger deletes every marker whose
  # folder row carries the flag alone, never an unmatched one.
  use Engram.DataCase, async: false

  alias Engram.Backfill.IdWindows
  alias Engram.DataMigrations.{ExplicitFolderReconcile, FolderMarkerDelete}
  alias Engram.{FolderRows, Folders, Notes, QueryPlan, QueryRecorder, Repo}

  setup do
    # #2645's path-hash stop asks the real ledger, as in prod: while a vault
    # holds markers it writes their path hashes, which this delete matches.
    # (The test env pins `true`, a state a vault with markers never reaches.)
    Application.put_env(:engram, :path_hash_stop_markers_gone, FolderMarkerDelete)
    on_exit(fn -> Application.put_env(:engram, :path_hash_stop_markers_gone, true) end)
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

      QueryPlan.assert_explicit_index_bound!(plan)

      refute plan =~ "Seq Scan on notes", plan
    end
  end

  # Notes read by primary key, bound to named ids: an index scan or, as CI's
  # statistics draw it, a bitmap scan of `notes_pkey`, either one with
  # `id = ...` as its Index Cond (a bitmap scan without it walks the index).
  @notes_by_id ~r/(?:Scan using notes_pkey on notes \w+|Bitmap Index Scan on notes_pkey)\s*\n\s*Index Cond: \(id = /

  test "the notes-by-id check refuses an unbound notes_pkey scan" do
    bound = "->  Bitmap Index Scan on notes_pkey\n      Index Cond: (id = ANY ($1))"
    assert bound =~ @notes_by_id

    assert "->  Index Scan using notes_pkey on notes n\n  Index Cond: (id = ANY ($1))" =~
             @notes_by_id

    refute "->  Bitmap Index Scan on notes_pkey\n      Filter: (kind = 'folder')" =~ @notes_by_id
    refute "->  Bitmap Index Scan on notes_pkey\n  Index Cond: (vault_id = $1)" =~ @notes_by_id
    refute "->  Index Scan using notes_pkey on notes n\n  Filter: (id = ANY ($1))" =~ @notes_by_id
  end

  # #2652 re-review L1: the window's statements (lock the markers, stamp
  # their folder rows, delete the markers), recorded from a real pass and
  # planned as the fleet role, EXPLAIN only. Every folders read bound to the
  # tenant and the vault or a primary-key probe, notes by primary key, custom
  # and generic plans, nested loops on and off (a planner that would rather
  # hash must have no tenant-wide side to hash).
  #
  # Statistics shapes: first `folders` rewritten and analyzed with only this
  # vault's rows (`QueryPlan.fresh!/1`, so earlier tests' leftovers cannot
  # decide it), the shape where 0.91.0's stamp read
  # `folders_explicit_user_vault` with no condition (every tenant's explicit
  # rows); then 40 other tenants' explicit rows
  # under the 2639 shapes (n_distinct 40/40, -1/40, dead explicit entries).
  test "plans the delete as engram_maintenance", %{user: u, vault: v} do
    for i <- 1..10, do: {:ok, _} = Folders.create_markers(u, v, ["D#{i}"])
    stop_on!()

    Repo.query!("ANALYZE notes")
    QueryPlan.fresh!("folders")
    assert_window_plans!(u, "own vault only")
    assert_stamp_unnamed!()

    for _ <- 1..40 do
      {:ok, other} = Engram.Fixtures.user_with_dek_fixture()
      ov = insert(:vault, user: other)
      {:ok, _} = Folders.create_markers(other, ov, Enum.map(1..25, &"O#{&1}"))
    end

    Repo.query!("ANALYZE notes")

    for {users, vaults, dead} <- [{40, 40, 0}, {-1, 40, 0}, {40, 40, 1500}] do
      if dead > 0, do: QueryPlan.dead_explicit_folders!(dead)
      QueryPlan.folders_tenant_shape!(users, vaults)
      assert_window_plans!(u, "n_distinct #{users}/#{vaults}, #{dead} dead rows")
    end
  end

  # One pass over the vault's markers, rolled back, its statements recorded;
  # then the window's statements planned: the vault lock, locking the markers
  # (and probing their folder rows), the stamp, the delete, the leftover
  # count. The unmatched-vaults check has its own plan test above.
  defp assert_window_plans!(user, label) do
    me = self()

    {:error, {:recorded, queries}} =
      Repo.transaction(fn ->
        {_, queries} = QueryRecorder.record(fn -> FolderMarkerDelete.run_pass() end)
        Repo.rollback({:recorded, queries})
      end)

    statements =
      for %{sql: sql, params: params, pid: ^me} <- queries,
          sql =~
            ~r/FOR UPDATE OF n|UPDATE folders|DELETE FROM notes|FROM vaults|count\(\*\)::int FROM w/,
          do: {sql, params}

    assert Enum.any?(statements, fn {sql, _} -> sql =~ "UPDATE folders" end),
           "#{label}: the pass stamped nothing\n#{inspect(queries, pretty: true)}"

    for nestloop <- ["on", "off"], {sql, params} <- statements do
      Repo.query!("SET LOCAL enable_nestloop = #{nestloop}")

      %{custom: custom, generic: generic} =
        QueryPlan.rls_plans(user.id, sql, params, role: "engram_maintenance", analyze: false)

      # The stamp runs unnamed (`assert_stamp_unnamed!/0`), so only its custom
      # plan ever runs.
      plans = if stamp?(sql), do: [custom: custom], else: [custom: custom, generic: generic]

      for {kind, plan} <- plans do
        msg = "#{label}, #{kind} plan, enable_nestloop #{nestloop}\n#{sql}"
        assert_window_plan!(sql, plan, msg)
      end
    end

    Repo.query!("SET LOCAL enable_nestloop = on")
  end

  defp stamp?(sql), do: String.starts_with?(String.trim_leading(sql), "UPDATE folders")

  # Seven passes (Postgres may switch a NAMED statement to a generic plan
  # from its 6th run): the stamp is never prepared by name.
  defp assert_stamp_unnamed! do
    for _ <- 1..7 do
      Repo.transaction(fn ->
        FolderMarkerDelete.run_pass()
        Repo.rollback(:pass)
      end)
    end

    assert Repo.query!(
             "SELECT statement FROM pg_prepared_statements WHERE statement LIKE '%UPDATE folders%'"
           ).rows == []
  end

  defp assert_window_plan!(sql, plan, msg) do
    full = msg <> "\n" <> plan
    refute plan =~ "Seq Scan on notes", full
    # Every notes index read has a condition (a partial index read with none,
    # even inside a BitmapAnd, is every account's rows of that index).
    refute plan =~ ~r/(?:Scan using|Bitmap Index Scan on) notes_\w+[^\n]*\n(?!\s*Index Cond)/,
           "notes index read with no condition\n" <> full

    if sql =~ "DELETE FROM notes", do: assert(plan =~ @notes_by_id, full)

    # The stamp at the pinned shape is exempt (see the stamp check below).
    pinned_stamp? = stamp?(sql) and String.starts_with?(msg, "own vault only")

    if plan =~ ~r/on folders\b|on folders_/ and not pinned_stamp? do
      QueryPlan.assert_scans_vault_bound!(plan, fn -> msg end)
      QueryPlan.assert_explicit_index_bound!(plan, msg)
      assert_folder_reads_keyed!(plan, full)
    end

    # The stamp (a statement per folder row since the fix): the primary key
    # by a scalar id, and no other folders index. Checked at the 40-tenant
    # shapes only: the pinned one-vault shape tells the planner the whole
    # table is one vault, so a skip scan of `folders_vault_id_id_key` by
    # `id` costs the same as the key probe there. Prod has ~1,875 tenants;
    # the real-stats EXPLAIN of the stamp is in staging table F2 and the
    # flip runbook's step 1. The pinned shape still checks the lock and
    # probe statements.
    if stamp?(sql) and not pinned_stamp? do
      assert plan =~
               ~r/Index Scan using folders_pkey on folders\s*\n\s*Index Cond: \(id = '[0-9a-f-]{36}'::uuid\)\n/,
             "stamp is not a primary-key probe by scalar id\n" <> full

      assert length(Regex.scan(~r/Scan (?:using|on) folders\w*/, plan)) == 1,
             "stamp reads another folders index\n" <> full
    end

    # `notes_user_vault*` lead with `user_id`: read by `vault_id` alone they
    # are a skip scan over every tenant's entries.
    for [cond] <-
          Regex.scan(
            ~r/(?:Scan using|Bitmap Index Scan on) notes_user_vault\w*[^\n]*\n\s*Index Cond: ([^\n]*)/,
            plan,
            capture: :all_but_first
          ),
        do: assert(cond =~ "user_id =", "notes read without user_id: #{cond}\n" <> full)
  end

  # Every folders index read is a primary-key probe or names the tenant AND
  # the vault (Index Cond, or the Filter on the same node): a probe that
  # drops either binding fails here.
  defp assert_folder_reads_keyed!(plan, full) do
    for [node, lines] <-
          Regex.scan(
            ~r/((?:Index (?:Only )?Scan using|Bitmap Index Scan on) folders\w*[^\n]*)\n((?:\s+(?:Index Cond|Recheck Cond|Filter):[^\n]*\n?)*)/,
            plan,
            capture: :all_but_first
          ),
        not (node =~ "folders_pkey") do
      assert lines =~ "user_id =" and lines =~ "vault_id =",
             "folders read not bound by user_id and vault_id: " <> node <> "\n" <> full
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
  # floor at E (no rollback target reads markers), not just the stop on. The
  # floor-to-E raise reached it, so under `:enforce` (prod) the pass runs.
  test "at the rollback floor (release E): the pass runs under :enforce", ctx do
    %{user: _u, vault: v} = ctx
    {:ok, _} = Folders.create_markers(ctx.user, v, ["Fl"])
    Engram.ServiceConfig.put_override(:marker_stop_floors, :assume)
    Engram.ServiceConfig.put_override(:folder_marker_stop, true)
    assert Engram.Folders.MarkerStop.on?()
    assert FolderMarkerDelete.floors?(:enforce)

    Engram.ServiceConfig.put_override(:marker_delete_floors, :enforce)
    refute FolderMarkerDelete.run_pass() == {:more, rows: 0, blocked: 1}
    assert markers(v) == 0
  end
end
