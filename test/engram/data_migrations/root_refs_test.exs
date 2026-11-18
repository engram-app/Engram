defmodule Engram.DataMigrations.RootRefsTest do
  # S6 step 1b (Engram#2523): note writers point a root note at its vault's
  # root row (`Rows.root_id/1`), and the `root_refs` ledger fills the root
  # notes written before (or by a previous-release node), creating the root
  # row where a vault has none. Folder notes, drift and tombstones are not
  # touched; the kill switch stops every pass.
  use Engram.DataCase, async: false

  alias Engram.Backfill.IdWindows
  alias Engram.{Crypto, FolderRows, Notes, ServiceConfig}
  alias Engram.DataMigrations.RootRefs
  alias Engram.Folders.Rows
  alias Engram.Workers.DataMigrationsRunner

  setup do
    IdWindows.reset_walk(RootRefs.name())
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp dump(id), do: Ecto.UUID.dump!(id)

  defp note!(u, v, path) do
    {:ok, n} = Notes.upsert_note(u, v, %{"path" => path, "content" => "x"}, actor: "api")
    n
  end

  # What a previous-release node leaves: a root note with no reference.
  defp old_release!(note),
    do: Repo.query!("UPDATE notes SET folder_ref_id = NULL WHERE id = $1", [dump(note.id)])

  defp drop_root!(vault),
    do: Repo.query!("DELETE FROM folders WHERE id = $1", [dump(Rows.root_id(vault.id))])

  defp run_to_done do
    Enum.reduce_while(1..20, nil, fn _, _ ->
      case RootRefs.run_pass() do
        :done -> {:halt, :done}
        more -> {:cont, more}
      end
    end)
  end

  defp root_name(user, vault) do
    {:ok, dek} = Crypto.get_dek(user)

    %{rows: [[ct, nonce, parent]]} =
      Repo.query!("SELECT name_ciphertext, name_nonce, parent_id FROM folders WHERE id = $1", [
        dump(Rows.root_id(vault.id))
      ])

    {Rows.decrypt_name(dek, vault.id, Crypto.row_version_aad_bound(), ct, nonce), parent}
  end

  describe "writers" do
    test "a root note names the root row; a folder note its folder", %{user: u, vault: v} do
      root = note!(u, v, "top.md")
      deep = note!(u, v, "A/n.md")

      assert FolderRows.ref("notes", root.id) == v.id
      assert FolderRows.ref("notes", deep.id) not in [nil, v.id]
      assert root_name(u, v) == {{:ok, ""}, nil}
    end

    test "a note moved to the root names the root row", %{user: u, vault: v} do
      n = note!(u, v, "A/n.md")
      {:ok, _} = Notes.rename_note(u, v, "A/n.md", "n.md")
      assert FolderRows.ref("notes", n.id) == v.id
    end

    test "a second root note reuses the row", %{user: u, vault: v} do
      note!(u, v, "a.md")
      note!(u, v, "b.md")

      assert %{rows: [[1]]} =
               Repo.query!("SELECT count(*)::int FROM folders WHERE vault_id = $1", [dump(v.id)])
    end
  end

  describe "ledger" do
    test "fills root notes and creates a missing root row", %{user: u, vault: v} do
      a = note!(u, v, "a.md")
      b = note!(u, v, "b.md")
      deep = note!(u, v, "A/n.md")
      drift = note!(u, v, "D/d.md")
      gone = note!(u, v, "gone.md")
      :ok = Notes.delete_note(u, v, "gone.md")
      Enum.each([a, b, drift, gone], &old_release!/1)
      drop_root!(v)

      assert run_to_done() == :done

      assert FolderRows.ref("notes", a.id) == v.id
      assert FolderRows.ref("notes", b.id) == v.id
      assert FolderRows.ref("notes", deep.id) not in [nil, v.id]
      # Drift is FolderTable's; a tombstone keeps its NULL.
      assert FolderRows.ref("notes", drift.id) == nil
      assert FolderRows.ref("notes", gone.id) == nil
      assert root_name(u, v) == {{:ok, ""}, nil}

      # Readers see one root holding both notes.
      {:ok, %{notes: page}} = Notes.list_notes_in_folder_page(u, v, "")
      assert page |> Enum.map(& &1.path) |> Enum.sort() == ["a.md", "b.md"]
    end

    test "below the rollback floor: writers and the ledger stay off", %{user: u, vault: v} do
      Application.put_env(:engram, :root_refs_floor, :enforce)
      on_exit(fn -> Application.put_env(:engram, :root_refs_floor, :assume) end)

      a = note!(u, v, "a.md")
      assert FolderRows.ref("notes", a.id) == nil
      assert RootRefs.run_pass() == {:more, rows: 0, blocked: 1}
      assert FolderRows.ref("notes", a.id) == nil
    end

    test "the kill switch runs no pass", %{user: u, vault: v} do
      a = note!(u, v, "a.md")
      old_release!(a)
      ServiceConfig.put_override(:root_refs, false)

      assert DataMigrationsRunner.run(RootRefs) == :skipped
      assert FolderRows.ref("notes", a.id) == nil
    end
  end
end
