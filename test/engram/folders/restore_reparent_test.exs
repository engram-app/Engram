defmodule Engram.Folders.RestoreReparentTest do
  # An undo whose top folder lost its name to a live sibling must not strand
  # the folders below it: they come back under the live row.
  use Engram.DataCase, async: false

  alias Engram.{Folders, Notes, Repo}
  alias Engram.FolderRows

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    %{user: user, vault: insert(:vault, user: user)}
  end

  defp put_note(user, vault, path) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => "# T\n\nbody"}, actor: "api")

    note
  end

  defp live_paths(user, vault) do
    {:ok, notes} = Notes.list_tree_notes(user, vault)
    notes |> Enum.map(& &1.path) |> Enum.sort()
  end

  setup %{user: u, vault: v} do
    put_note(u, v, "P/Child/Deep/n.md")
    op = Ecto.UUID.generate()
    assert {:ok, %{notes: 1}} = Folders.delete(u, v, "P", recursive: true, op_id: op)
    put_note(u, v, "P/new.md")
    assert {:ok, %{notes: 1}} = Folders.restore_op(u, v, op)
    %{op: op}
  end

  test "revived children hang off the live row, so the tree reaches them", %{user: u, vault: v} do
    assert live_paths(u, v) == ["P/Child/Deep/n.md", "P/new.md"]

    # Walking the live chain from every row works only if no live row hangs
    # off a dead parent; one live row per path.
    assert FolderRows.tree(u) |> Map.keys() |> Enum.sort() == ["P", "P/Child", "P/Child/Deep"]

    assert %{rows: [[3]]} =
             Repo.query!("SELECT count(*)::int FROM folders WHERE deleted_at IS NULL")
  end

  test "a later rename of the live folder moves the restored subtree", %{user: u, vault: v} do
    assert {:ok, _} = Folders.rename(u, v, "P", "Q")
    assert live_paths(u, v) == ["Q/Child/Deep/n.md", "Q/new.md"]
  end

  test "a later delete of the live folder takes the restored subtree", %{user: u, vault: v} do
    assert {:ok, %{notes: 2}} = Folders.delete(u, v, "P", recursive: true)
    assert live_paths(u, v) == []
  end
end
