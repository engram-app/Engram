defmodule Engram.Folders.FoldersTableTest do
  # Expand step of the folders table: the `folders` schema and its RLS, the
  # `folder_ref_id` columns with their keys and indexes, and the
  # `notes_set_folder_ref` trigger.
  use Engram.DataCase, async: false

  import Engram.RlsCase

  alias Engram.Crypto
  alias Engram.Notes
  alias Engram.Repo

  setup do
    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user)
    {:ok, filter_key} = Crypto.dek_filter_key(user)
    %{user: user, vault: vault, fk: filter_key}
  end

  defp dump(id), do: Ecto.UUID.dump!(id)
  defp hmac(fk, text), do: Crypto.hmac_field(fk, text)

  defp folder!(user, vault, name_hmac, opts \\ []),
    do: Engram.FolderRows.insert!(user, vault, name_hmac, opts)

  defp write!(user, vault, path) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => "# T\n\nbody"}, actor: "api")

    note
  end

  describe "folders table" do
    test "root folders of one name collide, other parents and tombstones do not", %{
      user: u,
      vault: v
    } do
      name = :crypto.strong_rand_bytes(32)
      root = folder!(u, v, name)

      # NULLS NOT DISTINCT: a second live root folder of the same name is refused.
      assert_raise Postgrex.Error, ~r/folders_live_name/, fn -> folder!(u, v, name) end

      # The same name under a parent is a different folder.
      child = folder!(u, v, name, parent: root)

      assert_raise Postgrex.Error, ~r/folders_live_name/, fn ->
        folder!(u, v, name, parent: root)
      end

      assert child != root

      # A tombstone does not hold the name, and another vault has its own namespace.
      folder!(u, v, :crypto.strong_rand_bytes(32), deleted_at: ~U[2026-10-27 00:00:00Z])
      tomb_name = :crypto.strong_rand_bytes(32)
      folder!(u, v, tomb_name, deleted_at: ~U[2026-10-27 00:00:00Z])
      folder!(u, v, tomb_name)
      other = insert(:vault, user: u)
      folder!(u, other, name)
    end

    test "a parent in another vault is refused", %{user: u, vault: v} do
      other = insert(:vault, user: u)
      foreign = folder!(u, other, :crypto.strong_rand_bytes(32))

      assert_raise Postgrex.Error, ~r/folders_parent_fk/, fn ->
        folder!(u, v, :crypto.strong_rand_bytes(32), parent: foreign)
      end
    end

    test "deleting the vault deletes its folders", %{user: u, vault: v} do
      root = folder!(u, v, :crypto.strong_rand_bytes(32))
      folder!(u, v, :crypto.strong_rand_bytes(32), parent: root)

      Repo.query!("DELETE FROM vaults WHERE id = $1", [dump(v.id)])

      assert %{rows: [[0]]} = Repo.query!("SELECT count(*)::int FROM folders")
    end

    test "RLS is forced with a tenant and a maintenance policy" do
      assert %{rows: [[true, true]]} =
               Repo.query!(
                 "SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE relname = 'folders'"
               )

      assert %{rows: rows} =
               Repo.query!("SELECT polname FROM pg_policy WHERE polrelid = 'folders'::regclass")

      assert Enum.sort(List.flatten(rows)) == ["maintenance_all", "tenant_isolation_folders"]
    end

    test "control: the dropped role with no tenant sees zero rows", %{user: u, vault: v} do
      folder!(u, v, :crypto.strong_rand_bytes(32))
      assert %{rows: [[1]]} = Repo.query!("SELECT count(*)::int FROM folders")

      assert {:returned, %{rows: [[0]]}} =
               as_prod_role(fn -> Repo.query!("SELECT count(*)::int FROM folders") end)
    end

    test "a tenant sees only its own folders", %{user: u, vault: v} do
      mine = folder!(u, v, :crypto.strong_rand_bytes(32))
      other = insert(:user)
      folder!(other, insert(:vault, user: other), :crypto.strong_rand_bytes(32))

      assert {:returned, {:ok, %{rows: [[id]]}}} =
               as_prod_role(fn ->
                 Repo.with_tenant(u.id, fn -> Repo.query!("SELECT id FROM folders") end)
               end)

      assert Ecto.UUID.load!(id) == mine
    end
  end

  describe "folder_ref_id" do
    test "exists on notes and attachments, nullable, keys valid, indexes valid" do
      assert %{rows: [["attachments", "uuid", "YES", nil], ["notes", "uuid", "YES", nil]]} =
               Repo.query!("""
               SELECT table_name, data_type, is_nullable, column_default
               FROM information_schema.columns
               WHERE column_name = 'folder_ref_id' ORDER BY table_name
               """)

      assert %{rows: [[true], [true]]} =
               Repo.query!("""
               SELECT convalidated FROM pg_constraint
               WHERE conname IN ('notes_folder_ref_fk', 'attachments_folder_ref_fk')
               """)

      assert %{rows: [[true], [true]]} =
               Repo.query!("""
               SELECT i.indisvalid FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
               WHERE c.relname IN ('notes_folder_ref', 'attachments_folder_ref')
               """)
    end

    test "a note cannot reference another vault's folder", %{user: u, vault: v, fk: fk} do
      other = insert(:vault, user: u)
      foreign = folder!(u, other, hmac(fk, "x"))
      note = write!(u, v, "A.md")

      assert_raise Postgrex.Error, ~r/notes_folder_ref_fk/, fn ->
        Repo.query!("UPDATE notes SET folder_ref_id = $1 WHERE id = $2", [
          dump(foreign),
          dump(note.id)
        ])
      end
    end
  end
end
