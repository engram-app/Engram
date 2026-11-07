defmodule Engram.Notes.NameWritersTest do
  # O(1) folder rename plan, S2 expand (Engram#2523): every writer of a note or
  # attachment path also writes the row's own name (`Engram.Notes.Name`) and
  # its folder row (`folder_ref_id`), and every folder row writer its
  # `name_ci_hmac`. Nothing reads them yet (S3). Red before S2: the columns
  # did not exist.
  use Engram.DataCase, async: false

  alias Engram.Attachments
  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Folders
  alias Engram.Folders.Folder
  alias Engram.Notes
  alias Engram.Notes.Name
  alias Engram.Repo

  setup do
    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp note!(user, vault, path, content \\ "# T\n\nbody") do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => path, "content" => content})
    note
  end

  defp attachment!(user, vault, path) do
    {:ok, att} =
      Attachments.upsert_attachment(user, vault, %{path: path, content: <<137, 80, 78, 71, 1>>})

    att
  end

  defp raw(table, id) when table in ["notes", "attachments"] do
    %{rows: [[ct, nonce, h, ci, stamp, path_nonce, ref]]} =
      Repo.query!(
        "SELECT name_ciphertext, name_nonce, name_hmac, name_ci_hmac, name_stamp, path_nonce, " <>
          "folder_ref_id FROM #{table} WHERE id = $1",
        [Ecto.UUID.dump!(id)]
      )

    %{ct: ct, nonce: nonce, hmac: h, ci: ci, stamp: stamp, path_nonce: path_nonce, ref: ref}
  end

  # The folder row a path's folder resolves to, by walking the live tree.
  defp folder_id(_user, ""), do: nil

  defp folder_id(user, folder) do
    %{^folder => %{id: id}} = Engram.FolderRows.tree(user)
    Ecto.UUID.dump!(id)
  end

  defp assert_named(user, table, id, path) do
    {:ok, dek} = Crypto.get_dek(user)
    {:ok, fk} = Crypto.dek_filter_key(user)
    row = raw(table, id)
    name = path |> String.split("/") |> List.last()
    folder = path |> String.split("/") |> Enum.drop(-1) |> Enum.join("/")

    assert {:ok, ^name} =
             Name.decrypt(String.to_existing_atom(table), dek, id, row.ct, row.nonce)

    assert row.hmac == Name.hmac(fk, name)
    assert row.ci == Name.ci_hmac(fk, name)
    assert row.stamp == Name.stamp(row.path_nonce)
    assert row.ref == folder_id(user, folder)
  end

  describe "Name" do
    test "keys/6 round-trips through decrypt and binds the row id", %{user: user} do
      {:ok, dek} = Crypto.get_dek(user)
      {:ok, fk} = Crypto.dek_filter_key(user)
      id = Ecto.UUID.generate()
      kw = Name.keys(:notes, dek, fk, id, "A/B/Report.MD", <<1, 2, 3>>)

      assert {:ok, "Report.MD"} = Name.decrypt(:notes, dek, id, kw[:name_ciphertext], kw[:name_nonce])

      # Another row's AAD does not open it.
      assert :error =
               Name.decrypt(:notes, dek, Ecto.UUID.generate(), kw[:name_ciphertext], kw[:name_nonce])

      assert kw[:name_stamp] == <<1, 2, 3>> <> Name.version()
      # Case folds for the ci key only.
      assert Name.ci_hmac(fk, "report.md") == kw[:name_ci_hmac]
      refute Name.hmac(fk, "report.md") == kw[:name_hmac]
      # Own domains: never a basename or path key.
      refute kw[:name_hmac] == Crypto.hmac_field(fk, "Report.MD")
    end

    test "a root path is its own name", %{user: user} do
      {:ok, dek} = Crypto.get_dek(user)
      {:ok, fk} = Crypto.dek_filter_key(user)
      id = Ecto.UUID.generate()
      kw = Name.keys(:attachments, dek, fk, id, "a.png", "n")
      assert {:ok, "a.png"} = Name.decrypt(:attachments, dek, id, kw[:name_ciphertext], kw[:name_nonce])
    end
  end

  describe "note writers" do
    test "create, at the root and in a folder", %{user: u, vault: v} do
      root = note!(u, v, "Root.md")
      deep = note!(u, v, "A/B/Deep.md")
      assert_named(u, "notes", root.id, "Root.md")
      assert_named(u, "notes", deep.id, "A/B/Deep.md")
    end

    test "a content edit keeps the name current", %{user: u, vault: v} do
      note = note!(u, v, "A/Edit.md")
      before = raw("notes", note.id)
      note!(u, v, "A/Edit.md", "# T\n\nchanged")
      assert_named(u, "notes", note.id, "A/Edit.md")
      # The path did not change, so neither did the name (no extra churn).
      assert raw("notes", note.id).nonce == before.nonce
    end

    test "rename and move", %{user: u, vault: v} do
      note = note!(u, v, "A/Old.md")
      {:ok, _} = Notes.rename_note(u, v, "A/Old.md", "A/New.md")
      assert_named(u, "notes", note.id, "A/New.md")

      {:ok, _} = Notes.rename_note(u, v, "A/New.md", "B/C/New.md")
      assert_named(u, "notes", note.id, "B/C/New.md")
    end

    test "folder rename cascade", %{user: u, vault: v} do
      a = note!(u, v, "Old/a.md")
      b = note!(u, v, "Old/Sub/b.md")
      {:ok, _} = Folders.rename(u, v, "Old", "New")
      assert_named(u, "notes", a.id, "New/a.md")
      assert_named(u, "notes", b.id, "New/Sub/b.md")
    end

    test "CRDT create and CRDT relocation", %{user: u, vault: v} do
      id = Ecto.UUID.generate()
      {:ok, _} = Notes.genesis_crdt_note(u, v, id, "Src/crdt.md")
      assert_named(u, "notes", id, "Src/crdt.md")

      {:ok, _} = Notes.genesis_crdt_note(u, v, id, "Dst/crdt2.md")
      assert_named(u, "notes", id, "Dst/crdt2.md")
    end

    test "restore of an undoable delete", %{user: u, vault: v} do
      note = note!(u, v, "Trash/r.md")
      op = Ecto.UUID.generate()
      :deleted = Notes.delete_note_reporting(u, v, "Trash/r.md", op_id: op)
      {:ok, %{notes: 1}} = Folders.restore_op(u, v, op)
      assert_named(u, "notes", note.id, "Trash/r.md")
    end
  end

  describe "attachment writers" do
    test "create, move and folder rename", %{user: u, vault: v} do
      att = attachment!(u, v, "Img/a.png")
      assert_named(u, "attachments", att.id, "Img/a.png")

      {:ok, _} = Attachments.move_attachment(u, v, "Img/a.png", "Pics/b.png")
      assert_named(u, "attachments", att.id, "Pics/b.png")

      {:ok, _} = Folders.rename(u, v, "Pics", "Photos")
      assert_named(u, "attachments", att.id, "Photos/b.png")
    end

    test "restore of an undoable delete", %{user: u, vault: v} do
      att = attachment!(u, v, "R/a.png")
      op = Ecto.UUID.generate()
      :deleted = Attachments.delete_attachment_reporting(u, v, "R/a.png", op_id: op)
      {:ok, %{attachments: 1}} = Folders.restore_op(u, v, op)
      assert_named(u, "attachments", att.id, "R/a.png")
    end
  end

  describe "folder rows" do
    defp folder_rows(user) do
      {:ok, dek} = Crypto.get_dek(user)

      %{rows: rows} =
        Repo.query!(
          "SELECT id, name_ciphertext, name_nonce, name_ci_hmac, name_stamp FROM folders " <>
            "WHERE user_id = $1 AND deleted_at IS NULL",
          [Ecto.UUID.dump!(user.id)]
        )

      Map.new(rows, fn [id, ct, nonce, ci, stamp] ->
        id = Ecto.UUID.load!(id)
        {:ok, name} = Envelope.decrypt(ct, nonce, dek, Crypto.aad_for_row(:folders, :name, id))
        {name, %{ci: ci, stamp: stamp, nonce: nonce}}
      end)
    end

    test "created and renamed rows carry a current name_ci_hmac", %{user: u, vault: v} do
      {:ok, fk} = Crypto.dek_filter_key(u)
      note!(u, v, "Alpha/Beta/n.md")

      for name <- ["Alpha", "Beta"] do
        row = folder_rows(u)[name]
        assert row.ci == Folder.name_ci_hmac(fk, name)
        assert row.stamp == Name.stamp(row.nonce)
      end

      {:ok, _} = Folders.rename(u, v, "Alpha", "GAMMA")
      row = folder_rows(u)["GAMMA"]
      assert row.ci == Folder.name_ci_hmac(fk, "gamma")
      assert row.stamp == Name.stamp(row.nonce)
    end
  end
end
