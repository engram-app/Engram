defmodule Engram.Folders.ReviewFixesTest do
  # Fixes from the adversarial review of the writers/readers step: a folder
  # cannot become its own ancestor, a note pointing at a dead folder row is
  # still found, and the backfill and listings survive bad rows.
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Engram.{Attachments, Folders, Notes, Repo}
  alias Engram.DataMigrations.FolderTable
  alias Engram.FolderRows
  alias Engram.Folders.{Folder, Rows}

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
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

  defp folder_rows(user, vault) do
    {:ok, rows} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(from(f in Folder, where: f.vault_id == ^vault.id))
      end)

    rows
  end

  describe "H1: a folder never becomes its own ancestor" do
    test "rename into its own subtree is refused and touches nothing", %{user: u, vault: v} do
      put_note(u, v, "A/x.md")
      before = folder_rows(u, v)

      assert {:error, :invalid_path} = Folders.rename(u, v, "A", "A/B")
      assert {:error, :invalid_path} = Folders.rename(u, v, "A", "A/B/C")
      assert {:error, :invalid_path} = Notes.rename_folder(u, v, "A", "A/B")

      assert folder_rows(u, v) == before
      assert live_paths(u, v) == ["A/x.md"]
      # And the vault still works: this is the call that used to hang.
      assert {:ok, %{notes: 1}} = Folders.delete(u, v, "A", recursive: true)
    end

    test "renaming a folder onto itself stays a no-op", %{user: u, vault: v} do
      put_note(u, v, "A/x.md")
      assert {:ok, _} = Folders.rename(u, v, "A", "A")
    end

    test "the database refuses a self-parent", %{user: u, vault: v} do
      id =
        Ecto.UUID.dump!(put_note(u, v, "A/x.md") |> then(fn _ -> FolderRows.tree(u)["A"].id end))

      assert_raise Postgrex.Error, ~r/folders_not_own_parent/, fn ->
        Repo.query!("UPDATE folders SET parent_id = id WHERE id = $1", [id])
      end
    end

    test "a cycle in the data cannot hang the subtree walk", %{user: u, vault: v} do
      put_note(u, v, "A/B/x.md")
      t = FolderRows.tree(u)
      a = Ecto.UUID.dump!(t["A"].id)
      b = Ecto.UUID.dump!(t["A/B"].id)
      # A two-row loop: the CHECK only forbids the shortest one.
      Repo.query!("UPDATE folders SET parent_id = $1 WHERE id = $2", [b, a])

      task = Task.async(fn -> Repo.with_tenant(u.id, fn -> Rows.subtree(u, v.id, ["A"]) end) end)
      assert {:ok, {:ok, rows}} = Task.yield(task, 5_000) || Task.shutdown(task)
      assert length(rows) == length(Enum.uniq_by(rows, & &1.id))
    end
  end

  describe "H2: a note pointing at a dead folder row is still found" do
    test "delete X, recreate X, undo the first delete, delete X again", %{user: u, vault: v} do
      put_note(u, v, "X/old.md")
      op = Ecto.UUID.generate()
      assert {:ok, %{notes: 1}} = Folders.delete(u, v, "X", recursive: true, op_id: op)
      put_note(u, v, "X/new.md")

      assert {:ok, %{notes: 1}} = Folders.restore_op(u, v, op)
      assert live_paths(u, v) == ["X/new.md", "X/old.md"]

      # The restored note was re-pointed at the live row, and the delete takes both.
      live_id = FolderRows.tree(u)["X"].id
      assert {:ok, %{notes: 2}} = Folders.delete(u, v, "X", recursive: true)
      assert live_paths(u, v) == []
      _ = live_id
    end

    test "a ref to a deleted row is treated as unresolved by every scan", %{user: u, vault: v} do
      note = put_note(u, v, "Y/n.md")
      row = FolderRows.tree(u)["Y"].id
      Repo.query!("UPDATE folders SET deleted_at = now() WHERE id = $1", [Ecto.UUID.dump!(row)])
      assert FolderRows.ref("notes", note.id) == row

      {:ok, rows} = Notes.scan_folders(u, v, ["Y"])
      assert Enum.map(rows, & &1.path) == ["Y/n.md"]

      assert {:ok, 1} = Folders.rename(u, v, "Y", "Z") |> then(fn {:ok, r} -> {:ok, r.notes} end)
      assert live_paths(u, v) == ["Z/n.md"]
    end

    test "a folder row with live content is not deleted from under it", %{user: u, vault: v} do
      put_note(u, v, "W/Sub/n.md")
      t = FolderRows.tree(u)

      # Rows are soft-deleted while a note still points at the subfolder.
      deleted = Repo.with_tenant!(u.id, fn -> Rows.soft_delete(u, v.id, ["W"], nil) end)
      assert deleted == 0
      assert FolderRows.row(t["W/Sub"].id).deleted_at == nil
      assert FolderRows.row(t["W"].id).deleted_at == nil
    end

    test "a restored attachment is re-pointed at the live row", %{user: u, vault: v} do
      {:ok, att} =
        Attachments.upsert_attachment(u, v, %{
          "path" => "P/a.png",
          "content_base64" => Base.encode64("bytes")
        })

      op = Ecto.UUID.generate()
      assert {:ok, _} = Folders.delete(u, v, "P", recursive: true, op_id: op)

      {:ok, _} =
        Attachments.upsert_attachment(u, v, %{
          "path" => "P/b.png",
          "content_base64" => Base.encode64("b")
        })

      assert {:ok, %{attachments: 1}} = Folders.restore_op(u, v, op)

      assert FolderRows.ref("attachments", att.id) == FolderRows.tree(u)["P"].id
    end
  end

  describe "backfill hardening" do
    test "a user under a DEK rotation lock is skipped and written nothing", %{user: u, vault: v} do
      Engram.Fixtures.insert_note!(u, v, %{path: "L/n.md", content: "x"})

      Repo.query!("UPDATE users SET dek_rotation_locked_at = now() WHERE id = $1", [
        Ecto.UUID.dump!(u.id)
      ])

      assert {:more, opts} = FolderTable.run_pass(user_ids: [u.id])
      assert opts[:blocked] == 1
      assert folder_rows(u, v) == []

      Repo.query!("UPDATE users SET dek_rotation_locked_at = NULL WHERE id = $1", [
        Ecto.UUID.dump!(u.id)
      ])

      assert {:more, _} = FolderTable.run_pass(user_ids: [u.id])
      assert FolderRows.tree(u)["L"]
    end

    test "the attachment walk has no cap: it pages to the end", %{user: u, vault: v} do
      for i <- 1..5 do
        {:ok, _} =
          Attachments.upsert_attachment(u, v, %{
            "path" => "Big/p#{i}.png",
            "content_base64" => Base.encode64("b#{i}")
          })
      end

      Repo.query!("UPDATE attachments SET folder_ref_id = NULL")
      assert {:more, _} = FolderTable.run_pass(user_ids: [u.id], batch: 2)
      assert FolderTable.run_pass(user_ids: [u.id], batch: 2) == :done
    end

    test "running out of time is more work, not a failure", %{user: u, vault: v} do
      for i <- 1..3 do
        {:ok, _} =
          Attachments.upsert_attachment(u, v, %{
            "path" => "T/p#{i}.png",
            "content_base64" => Base.encode64("b#{i}")
          })
      end

      Repo.query!("UPDATE attachments SET folder_ref_id = NULL")

      assert {:more, opts} =
               FolderTable.run_pass(user_ids: [u.id], batch: 1, attachment_budget_ms: -1)

      assert opts[:blocked] == 0
    end

    test "a marker whose UUID names a tombstoned row revives it instead of failing", ctx do
      %{user: u, vault: v} = ctx
      {:ok, %{folders: [%{id: marker}]}} = Notes.create_folder_markers(u, v, ["Mk"])

      Repo.query!("UPDATE folders SET deleted_at = now() WHERE id = $1", [Ecto.UUID.dump!(marker)])

      assert {:more, _} = FolderTable.run_pass(user_ids: [u.id])
      assert FolderRows.tree(u)["Mk"].id == marker
    end
  end

  describe "a listing survives an undecryptable folder row" do
    test "the bad folder is left out, the rest is served, and it is reported", ctx do
      %{user: u, vault: v} = ctx
      put_note(u, v, "Good/a.md")
      put_note(u, v, "Bad/b.md")
      bad = FolderRows.tree(u)["Bad"].id

      Repo.query!("UPDATE folders SET name_ciphertext = '\\x00' WHERE id = $1", [
        Ecto.UUID.dump!(bad)
      ])

      handler = "bad-folder-#{System.unique_integer([:positive])}"
      test = self()

      :telemetry.attach(
        handler,
        [:engram, :folders, :row_undecryptable],
        fn _, m, _, _ -> send(test, {:undecryptable, m.count}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, counts} = Notes.list_folders_with_counts(u, v)
      assert Enum.map(counts, & &1.folder) == ["Good"]
      assert_received {:undecryptable, 1}
      assert {:ok, ["Good"]} = Notes.list_folders(u, v)
    end
  end
end
