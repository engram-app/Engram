defmodule Engram.Folders.LockAndRefusalTest do
  # Folder row writers take the vault lock like a rename does, and a rename
  # whose row-level guard refuses after the path claim fails cleanly.
  use Engram.DataCase, async: false

  alias Engram.{Folders, Notes, QueryRecorder, Repo}
  alias Engram.FolderRows
  alias Engram.Folders.Rows

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

  test "soft_delete and restore_op lock the vault row before updating folders", %{
    user: u,
    vault: v
  } do
    put_note(u, v, "A/B/x.md")
    op = Ecto.UUID.generate()

    {_, queries} =
      QueryRecorder.record(fn ->
        Repo.with_tenant!(u.id, fn -> Rows.soft_delete(u, v.id, ["A"], op) end)
        Repo.with_tenant!(u.id, fn -> Rows.restore_op(v.id, op) end)
      end)

    for tx <- QueryRecorder.transactions(queries) do
      lock = Enum.find_index(tx, &(&1 =~ ~r/FROM vaults.*FOR NO KEY UPDATE/is))
      write = Enum.find_index(tx, &(&1 =~ ~r/UPDATE "?folders"?/i))
      assert lock, "no vault lock in: #{inspect(tx)}"
      assert write == nil or lock < write
    end
  end

  test "a rename the row guard refuses after the claim returns the error and moves nothing", %{
    user: u,
    vault: v
  } do
    put_note(u, v, "A/x.md")
    put_note(u, v, "B/y.md")
    t = FolderRows.tree(u)

    # Between the pre-check and the write transaction (the seq bump) another
    # move makes B a child of A: the new parent is now inside the moving subtree.
    Repo.query!("""
    CREATE FUNCTION race_move() RETURNS trigger LANGUAGE plpgsql AS
    $$ BEGIN
         UPDATE folders SET parent_id = '#{t["A"].id}' WHERE id = '#{t["B"].id}';
         RETURN NEW;
       END $$
    """)

    Repo.query!("""
    CREATE TRIGGER race_move BEFORE UPDATE OF change_seq ON vaults
    FOR EACH ROW WHEN (NEW.id = '#{v.id}') EXECUTE FUNCTION race_move()
    """)

    assert {:error, :invalid_path} = Notes.rename_folder(u, v, "A", "B/Z")
    assert live_paths(u, v) == ["A/x.md", "B/y.md"]
    _ = Folders
  end
end
