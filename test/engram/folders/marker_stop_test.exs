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
