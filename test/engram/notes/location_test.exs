defmodule Engram.Notes.LocationTest do
  # O(1) folder rename plan, S3 read switch (Engram#2523): with the S2
  # `note_name` ledger done, a note is found by its folder chain plus its
  # name, and a live note's path is derived from the folder tree plus its
  # name. Writers still cascade, so the stored path agrees; these tests break
  # that agreement on purpose (a folder row renamed with no cascade, the S5
  # write shape; a corrupted path key; a stale name stamp) to prove which
  # source each reader trusts.
  #
  # async: false: the ledger answer is a node-wide cache entry.
  use Engram.DataCase, async: false

  alias Engram.Crypto
  alias Engram.DataMigrations
  alias Engram.Folders.Rows
  alias Engram.Notes
  alias Engram.Notes.{Location, Name}
  alias Engram.Repo
  alias Engram.ServiceConfig

  setup do
    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)

    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "A/B/x.md", "content" => "# X\n\nbody"},
        actor: "api"
      )

    on_exit(fn -> Engram.Cache.clear_local(:note_name) end)
    %{user: user, vault: vault, note: note}
  end

  defp names_on! do
    :ok = DataMigrations.mark_done("note_name", 1)
    Engram.Cache.clear_local(:note_name)
    assert Location.on?()
  end

  defp sql!(sql, params), do: Repo.query!(sql, params)

  defp dump(id), do: Ecto.UUID.dump!(id)

  # The path key of the row no longer names its path: a reader that still
  # matches `path_hmac` (or the trigger-derived `path_id`) cannot find it.
  defp corrupt_path_key!(id) do
    sql!("UPDATE notes SET path_hmac = $2 WHERE id = $1", [
      dump(id),
      :crypto.strong_rand_bytes(32)
    ])
  end

  # A folder rename that writes ONE folder row and nothing else (the S5
  # write shape): the notes under it keep their old stored path.
  defp rename_folder_row!(user, folder_id, new_name) do
    {:ok, dek} = Crypto.get_dek(user)
    {:ok, fk} = Crypto.dek_filter_key(user)
    {ct, nonce} = Rows.encrypt_name(dek, folder_id, new_name)

    sql!(
      "UPDATE folders SET name_ciphertext = $2, name_nonce = $3, name_hmac = $4 WHERE id = $1",
      [dump(folder_id), ct, nonce, Rows.name_hmac(fk, new_name)]
    )
  end

  defp folder_id(user, path), do: Engram.FolderRows.tree(user)[path].id

  defp found(user, vault, path) do
    case Notes.get_note(user, vault, path) do
      {:ok, note} -> note.id
      {:error, :not_found} -> nil
    end
  end

  describe "by-path lookup" do
    test "with the ledger done it reads the folder chain and the name, not the path key",
         %{user: u, vault: v, note: note} do
      corrupt_path_key!(note.id)
      assert found(u, v, "A/B/x.md") == nil, "precondition: the path read misses the row"

      names_on!()
      assert found(u, v, "A/B/x.md") == note.id
      assert Notes.note_exists?(u, v, "A/B/x.md")
    end

    test "a folder renamed with no cascade: found at the new path, not at the old one",
         %{user: u, vault: v, note: note} do
      rename_folder_row!(u, folder_id(u, "A/B"), "C")
      assert found(u, v, "A/B/x.md") == note.id, "precondition: the path read uses the old path"
      assert found(u, v, "A/C/x.md") == nil

      names_on!()
      assert found(u, v, "A/C/x.md") == note.id
      assert found(u, v, "A/B/x.md") == nil
      # The note reads back at the path it was found at, not its stored one.
      assert {:ok, %{path: "A/C/x.md", folder: "A/C"}} = Notes.get_note(u, v, "A/C/x.md")
    end

    test "the name is exact: another case of the same name is a different path",
         %{user: u, vault: v, note: note} do
      names_on!()
      assert found(u, v, "A/B/x.md") == note.id
      assert found(u, v, "A/B/X.md") == nil
      assert found(u, v, "a/B/x.md") == nil
    end

    test "a stale name stamp (a previous-release rename) falls back to the path",
         %{user: u, vault: v, note: note} do
      {:ok, fk} = Crypto.dek_filter_key(u)

      # The previous release renamed x.md to y.md: new path, old name keys.
      sql!(
        "UPDATE notes SET name_hmac = $2, name_ci_hmac = $3, name_stamp = $4 WHERE id = $1",
        [dump(note.id), Name.hmac(fk, "y.md"), Name.ci_hmac(fk, "y.md"), <<9, 9, 9>>]
      )

      names_on!()
      assert found(u, v, "A/B/x.md") == note.id
      assert found(u, v, "A/B/y.md") == nil
    end

    test "a row with no folder ref is read by its path", %{user: u, vault: v, note: note} do
      {:ok, root} =
        Notes.upsert_note(u, v, %{"path" => "r.md", "content" => "r"}, actor: "api")

      sql!("UPDATE notes SET folder_ref_id = NULL WHERE id = $1", [dump(note.id)])

      names_on!()
      assert found(u, v, "r.md") == root.id
      assert found(u, v, "A/B/x.md") == note.id
    end

    test "unfinished ledger: names are not read", %{user: u, vault: v, note: note} do
      rename_folder_row!(u, folder_id(u, "A/B"), "C")
      refute Location.on?()
      assert found(u, v, "A/B/x.md") == note.id
      assert found(u, v, "A/C/x.md") == nil
    end

    test "the name_reads override turns names off with the ledger done",
         %{user: u, vault: v, note: note} do
      rename_folder_row!(u, folder_id(u, "A/B"), "C")
      names_on!()
      ServiceConfig.put_override(:name_reads, false)
      refute Location.on?()
      assert found(u, v, "A/B/x.md") == note.id
    end

    test "get_notes_within (MCP get_notes) resolves each path by its folder and name",
         %{user: u, vault: v, note: note} do
      {:ok, other} =
        Notes.upsert_note(u, v, %{"path" => "D/x.md", "content" => "d"}, actor: "api")

      rename_folder_row!(u, folder_id(u, "A/B"), "C")
      names_on!()

      got =
        u
        |> Notes.get_notes_within(v, ["D/x.md", "A/C/x.md", "A/B/x.md", "nope.md"], 1_000_000)
        |> Enum.map(fn {path, fetch} -> {path, with(%{id: id} <- fetch.(), do: id)} end)

      assert got == [
               {"D/x.md", other.id},
               {"A/C/x.md", note.id},
               {"A/B/x.md", nil},
               {"nope.md", nil}
             ]
    end
  end

  describe "derived output paths" do
    test "the change feed serves the path derived from the folder tree, plus folder_id and name",
         %{user: u, vault: v, note: note} do
      b = folder_id(u, "A/B")
      rename_folder_row!(u, b, "C")

      {:ok, %{changes: [before]}} = Notes.list_changes_by_seq(u, v, 0)
      assert before.path == "A/B/x.md"
      refute Map.has_key?(before, :folder_id)

      names_on!()
      {:ok, %{changes: [change]}} = Notes.list_changes_by_seq(u, v, 0)
      assert change.id == note.id
      assert change.path == "A/C/x.md"
      assert change.folder == "A/C"
      assert change.folder_id == b
      assert change.name == "x.md"

      {:ok, %{changes: [meta]}} = Notes.list_changes_by_seq(u, v, 0, fields: :meta)
      assert meta.path == "A/C/x.md"
    end

    test "a tombstone keeps the path it was deleted at", %{user: u, vault: v} do
      :ok = Notes.delete_note(u, v, "A/B/x.md")
      rename_folder_row!(u, folder_id(u, "A/B"), "C")
      names_on!()

      {:ok, %{changes: changes}} = Notes.list_changes_by_seq(u, v, 0)
      assert [%{deleted: true, path: "A/B/x.md"} = tomb] = Enum.filter(changes, & &1.deleted)
      refute Map.has_key?(tomb, :folder_id)
    end

    test "put_paths/2 derives live rows across vaults and leaves the rest alone",
         %{user: u, vault: v, note: note} do
      v2 = insert(:vault, user: u)

      {:ok, n2} =
        Notes.upsert_note(u, v2, %{"path" => "A/B/x.md", "content" => "two"}, actor: "api")

      rename_folder_row!(u, folder_id_in(u, v, "A/B"), "C")
      names_on!()

      # Stored rows as a reader decrypts them: the stored path, still A/B.
      notes = for {vv, n} <- [{v, note}, {v2, n2}], do: stored!(u, vv, n.id)
      assert Enum.map(notes, & &1.path) == ["A/B/x.md", "A/B/x.md"]

      assert [%{path: "A/C/x.md", folder: "A/C"}, %{path: "A/B/x.md"}] =
               Location.put_paths(u, notes)
    end
  end

  defp stored!(user, vault, id) do
    {:ok, note} = Notes.get_note_row_by_id(user, vault, id)
    note
  end

  defp folder_id_in(user, vault, path) do
    Repo.with_tenant!(user.id, fn -> Rows.ids_by_path(user, vault.id, [path]) end)[path]
  end
end
