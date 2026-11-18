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
  defp stop_on!, do: Engram.ServiceConfig.put_override(:marker_stop_floors, :assume)

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

    # Release D again: the stop is off and a create writes a marker.
    Engram.ServiceConfig.put_override(:marker_stop_floors, :enforce)
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
    for i <- 1..30, do: {:ok, _} = Folders.create_markers(u, v, ["M#{i}"])
    other = insert(:vault, user: u)
    for i <- 1..30, do: {:ok, _} = Folders.create_markers(u, other, ["O#{i}"])
    ids = [Ecto.UUID.dump!(v.id)]
    owners = [Ecto.UUID.dump!(u.id)]

    unmatched =
      QueryPlan.rls_plans(u.id, FolderMarkerDelete.unmatched_sql(), [ids, owners],
        role: "engram_maintenance"
      )

    for plan <- [unmatched.custom, unmatched.generic] do
      # A `(user_id, vault_id)` range either way: the marker index, or (on a
      # test vault that holds nothing but markers, where the two cost the
      # same) the live-notes one. Never a scan of the tenant's notes.
      assert plan =~ ~r/notes_user_vault_(folder_marker|live)/, plan
      # The folder probe: by path hash, or the live explicit rows of the
      # vault (both bounded by the vault; the planner picks by statistics).
      assert plan =~ ~r/folders_(full_path|explicit_live)/, plan
      refute plan =~ ~r/Seq Scan on (notes|folders)/, plan
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
end
