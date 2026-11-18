defmodule Engram.DataMigrations.FolderMarkerDeleteTest do
  # S6 step 4: once markers stop, the ledger deletes every marker whose
  # folder row carries the flag alone, never an unmatched one.
  use Engram.DataCase, async: false

  alias Engram.Backfill.IdWindows
  alias Engram.DataMigrations.{ExplicitFolderReconcile, FolderMarkerDelete}
  alias Engram.{FolderRows, Folders, Notes, Repo}

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    Engram.ServiceConfig.put_override(:folder_marker_delete, true)
    IdWindows.reset_walk(FolderMarkerDelete.name())
    %{user: user, vault: insert(:vault, user: user)}
  end

  # Markers are written with the stop off (the test default), then it goes on.
  defp stop_on!, do: Engram.ServiceConfig.put_override(:marker_stop_floors, :assume)

  defp markers(vault) do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM notes WHERE vault_id = $1 AND kind = 'folder'", [
        Ecto.UUID.dump!(vault.id)
      ])

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
end
