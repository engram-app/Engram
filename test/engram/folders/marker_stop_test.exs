defmodule Engram.Folders.MarkerStopTest do
  # S6 step 4, phase 2 (Engram#2523): with markers stopped, a folder create
  # makes the `folders` row explicit and inserts no `kind = 'folder'` row;
  # every listing, delete and undo works from the flag, and the vault seq
  # moves on each change as the marker write moved it.
  use Engram.DataCase, async: false

  alias Engram.Backfill.IdWindows
  alias Engram.DataMigrations.ExplicitFolderReconcile
  alias Engram.{FolderRows, Folders, Notes, Repo, Vaults}
  alias Engram.Folders.{MarkerStop, Rows}

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    Engram.ServiceConfig.put_override(:marker_stop_floors, :assume)
    %{user: user, vault: insert(:vault, user: user)}
  end

  defp markers(vault) do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM notes WHERE vault_id = $1 AND kind = 'folder'", [
        Ecto.UUID.dump!(vault.id)
      ])

    n
  end

  defp seq(user, vault), do: Vaults.current_seq(user.id, vault.id)
  defp explicit(user, vault), do: elem(Notes.list_explicit_folders(user, vault), 1)

  test "the floor sentinel keeps the stop off until a release sets it" do
    refute MarkerStop.floors?(:enforce)
    assert MarkerStop.floors?(:assume)
  end

  test "a create writes no marker, lists the folder and moves the seq", %{user: u, vault: v} do
    before = seq(u, v)

    assert {:ok, %{folders: [%{name: "A/B", created: true, id: id}]}} =
             Folders.create_markers(u, v, ["A/B"])

    assert markers(v) == 0
    assert explicit(u, v) == ["A/B"]
    assert FolderRows.tree(u)["A/B"].id == id
    assert seq(u, v) > before

    # A re-create changes nothing and takes no seq.
    now = seq(u, v)
    assert {:ok, %{folders: [%{created: false}]}} = Folders.create_markers(u, v, ["A/B"])
    assert seq(u, v) == now
  end

  test "the single create returns the row's id", %{user: u, vault: v} do
    assert {:ok, %{id: id, folder: "S"}} = Notes.create_folder_marker(u, v, "S")
    assert FolderRows.tree(u)["S"].id == id
    assert markers(v) == 0
  end

  test "a marker-only delete clears the flag and moves the seq", %{user: u, vault: v} do
    {:ok, _} = Folders.create_markers(u, v, ["E"])
    before = seq(u, v)

    assert {:ok, :deleted} = Notes.delete_folder_marker(u, v, "E")
    assert explicit(u, v) == []
    assert seq(u, v) > before
    assert {:ok, :not_found} = Notes.delete_folder_marker(u, v, "E")
  end

  test "a delete and its undo bring an empty explicit folder back", %{user: u, vault: v} do
    {:ok, _} = Folders.create_markers(u, v, ["Gone/Inner"])
    op = Ecto.UUID.generate()
    before = seq(u, v)

    assert {:ok, _} = Folders.delete(u, v, "Gone", recursive: true, op_id: op)
    assert explicit(u, v) == []
    assert seq(u, v) > before

    assert {:ok, _} = Folders.restore_op(u, v, op)
    assert explicit(u, v) == ["Gone/Inner"]
    assert markers(v) == 0
  end

  test "a folder made explicit inside a doomed one after the delete's scan is kept", ctx do
    %{user: u, vault: v} = ctx
    {:ok, _} = Folders.create_markers(u, v, ["F"])
    since = seq(u, v)
    {:ok, _} = Folders.create_markers(u, v, ["F/New"])

    Repo.with_tenant!(u.id, fn -> Rows.soft_delete(u, v.id, ["F"], nil, since) end)

    assert explicit(u, v) == ["F", "F/New"]
  end

  # A create that lands between a delete's scan and its row delete, through
  # the public deletes: the seq read before the scan (`since_seq`) is what
  # keeps it. The create runs from a query hook on the first attachments read
  # (the scan's last leg), so it is after the seq read and before the rows go.
  defp create_during_scan(user, vault, folder, fun) do
    me = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:engram, :repo, :query],
      fn _, _, meta, _ ->
        if self() == me and meta[:source] == "attachments" and !Process.get(id) do
          Process.put(id, true)
          {:ok, _} = Folders.create_markers(user, vault, [folder])
        end
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    assert Process.get(id), "the hook never ran"
  end

  test "Folders.delete keeps a folder made explicit during its scan", %{user: u, vault: v} do
    {:ok, _} = Folders.create_markers(u, v, ["F"])

    create_during_scan(u, v, "F/New", fn ->
      assert {:ok, _} = Folders.delete(u, v, "F", recursive: true)
    end)

    assert "F/New" in explicit(u, v)
  end

  test "Folders.batch_delete keeps a folder made explicit during its scan", %{user: u, vault: v} do
    {:ok, %{folders: [%{id: id}]}} = Folders.create_markers(u, v, ["G"])

    create_during_scan(u, v, "G/New", fn ->
      assert {:ok, _} = Folders.batch_delete(u, v, [id], [])
    end)

    assert "G/New" in explicit(u, v)
  end

  test "kill switch: folder_marker_stop off, creates insert markers again", %{user: u, vault: v} do
    Engram.ServiceConfig.put_override(:folder_marker_stop, false)
    {:ok, _} = Folders.create_markers(u, v, ["K"])
    assert markers(v) == 1
    assert explicit(u, v) == ["K"]
  end

  test "an undo announces the explicit folders it brings back", %{user: u, vault: v} do
    {:ok, _} = Folders.create_markers(u, v, ["U"])
    op = Ecto.UUID.generate()
    {:ok, _} = Folders.delete(u, v, "U", recursive: true, op_id: op)
    :ok = EngramWeb.Endpoint.subscribe("sync:#{u.id}:#{v.id}")

    assert {:ok, _} = Folders.restore_op(u, v, op)

    assert_receive %Phoenix.Socket.Broadcast{
      event: "folders.batch",
      payload: %{op: "create", folders: ["U"]}
    }
  end

  # The retire keeper of a rename merge and an undo's merge target are made
  # explicit with no marker, so a reconcile walk must leave them explicit.
  test "a rename merge's keeper survives a reconcile", %{user: u, vault: v} do
    {:ok, _} = Folders.create_markers(u, v, ["A"])
    # B: a live row with nothing under it (its only note gone), so a rename
    # onto it merges A's row into B's.
    {:ok, n} = Notes.upsert_note(u, v, %{"path" => "B/n.md", "content" => "x"}, actor: "api")
    Repo.query!("UPDATE notes SET deleted_at = now() WHERE id = $1", [Ecto.UUID.dump!(n.id)])
    refute "B" in explicit(u, v)

    assert {:ok, _} = Folders.rename(u, v, "A", "B")
    assert "B" in explicit(u, v)

    assert reconcile!() == :done
    assert "B" in explicit(u, v)
  end

  test "an undo's merge target survives a reconcile", %{user: u, vault: v} do
    {:ok, _} = Folders.create_markers(u, v, ["M"])
    op = Ecto.UUID.generate()
    {:ok, _} = Folders.delete(u, v, "M", recursive: true, op_id: op)
    {:ok, _} = Notes.upsert_note(u, v, %{"path" => "M/n.md", "content" => "x"}, actor: "api")
    {:ok, _} = Folders.restore_op(u, v, op)
    assert "M" in explicit(u, v)

    assert reconcile!() == :done
    assert "M" in explicit(u, v)
  end

  test "Materialization counts a marker-less explicit folder as existing", %{user: u, vault: v} do
    {:ok, _} = Folders.create_markers(u, v, ["Mat"])
    {:ok, _} = Notes.upsert_note(u, v, %{"path" => "Mat/n.md", "content" => "x"}, actor: "api")

    assert markers(v) == 0
    assert {:ok, %{inserted: 0, existing: 1}} = Engram.Notes.Materialization.run(u, v)
    assert Engram.Notes.Materialization.orphans(u, v) == []
    assert markers(v) == 0
  end

  # A cleared folder whose flag a stale writer sets again (a pre-#2639
  # cascade's leftover) has no marker: the reconcile must still clear it,
  # which it does only when the clear dropped the create's `explicit_seq`.
  test "a cleared flag set again without a marker is reconciled away", %{user: u, vault: v} do
    {:ok, _} = Folders.create_markers(u, v, ["C"])
    assert {:ok, :deleted} = Notes.delete_folder_marker(u, v, "C")
    {:ok, _} = Notes.upsert_note(u, v, %{"path" => "C/n.md", "content" => "x"}, actor: "api")

    Repo.query!("UPDATE folders SET explicit = true WHERE id = $1", [
      Ecto.UUID.dump!(FolderRows.tree(u)["C"].id)
    ])

    assert "C" in explicit(u, v)
    assert reconcile!() == :done
    refute "C" in explicit(u, v)
  end

  defp reconcile! do
    IdWindows.reset_walk(ExplicitFolderReconcile.name())

    Enum.reduce_while(1..5, nil, fn _, _ ->
      case ExplicitFolderReconcile.run_pass() do
        :done -> {:halt, :done}
        more -> {:cont, more}
      end
    end)
  end

  test "control: with the floor enforced, creates still insert markers", %{user: u, vault: v} do
    Engram.ServiceConfig.put_override(:marker_stop_floors, :enforce)
    {:ok, _} = Folders.create_markers(u, v, ["M"])
    assert markers(v) == 1
    assert explicit(u, v) == ["M"]
  end

  test "the reconcile never clears a folder the stop made explicit", %{user: u, vault: v} do
    {:ok, _} = Folders.create_markers(u, v, ["Z"])
    IdWindows.reset_walk(ExplicitFolderReconcile.name())

    assert Enum.reduce_while(1..5, nil, fn _, _ ->
             case ExplicitFolderReconcile.run_pass() do
               :done -> {:halt, :done}
               more -> {:cont, more}
             end
           end) == :done

    assert explicit(u, v) == ["Z"]
  end

  # The reconcile is re-verified daily (#2639 audit); once the stop's floor is
  # reached a reopen must not send listings back to markers the stop no
  # longer writes.
  test "with the floor reached, a reopened reconcile does not move listings off the flag" do
    Engram.ServiceConfig.put_override(:explicit_folders_ledger, :read)

    Engram.DataMigrations.mark_done(
      Engram.DataMigrations.FolderTable.name(),
      Engram.DataMigrations.FolderTable.version()
    )

    Engram.DataCase.clear_request_caches()
    assert Rows.explicit_reads?()

    Engram.ServiceConfig.put_override(:marker_stop_floors, :enforce)
    Engram.DataCase.clear_request_caches()
    refute Rows.explicit_reads?()
  end
end
