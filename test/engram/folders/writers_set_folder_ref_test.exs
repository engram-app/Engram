defmodule Engram.Folders.WritersSetFolderRefTest do
  # R9.5 step 2: every writer of a note's or attachment's path sets
  # `folder_ref_id` itself, so the `notes_set_folder_ref` trigger (and its
  # restore twin) can be dropped by the contract step. The triggers stay as the
  # previous release's backstop; these tests DISABLE both and drive every write
  # path, then check every live row of the vault against the folder tree.
  #
  # The writes run as the prod-like `engram_app` (no SUPERUSER, no BYPASSRLS)
  # under FORCE RLS, through `Engram.RlsCase`
  # (docs/context/rls-enforcement-testing-traps.md). Only the DISABLE runs as
  # the suite's superuser (it needs the table owner), inside the sandbox
  # transaction, so it rolls back with the test. `async: false`: ALTER TABLE
  # takes an ACCESS EXCLUSIVE lock on `notes` until then.
  use Engram.DataCase, async: false

  import Engram.RlsCase

  alias Engram.Attachments
  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.FolderRows
  alias Engram.Folders
  alias Engram.Notes
  alias Engram.Notes.Helpers
  alias Engram.Repo

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)

    for t <- ~w(notes_set_folder_ref notes_set_folder_ref_on_restore),
        do: Repo.query!("ALTER TABLE notes DISABLE TRIGGER #{t}")

    %{user: user, vault: vault}
  end

  defp dump(id), do: Ecto.UUID.dump!(id)

  # `fun` as a request runs it: `engram_app`, no tenant around it (the code
  # opens its own tenant blocks).
  defp app!(fun), do: as_prod_role_committing(fun)

  defp note!(u, v, path) do
    {:ok, n} =
      app!(fn ->
        Notes.upsert_note(u, v, %{"path" => path, "content" => "# T\n\nbody"}, actor: "api")
      end)

    n
  end

  defp attachment!(u, v, path) do
    {:ok, a} =
      app!(fn ->
        Attachments.upsert_attachment(u, v, %{
          "path" => path,
          "content_base64" => Base.encode64("bytes of " <> path)
        })
      end)

    a
  end

  # Every live note and attachment of the vault names the live folder row at
  # its decrypted folder (nil at the root), and every attachment's reference
  # is stamped current. Vault-wide, so a writer the test drives cannot leave
  # any row it touched behind. Returns the number of rows checked.
  defp assert_refs!(u, v) do
    tree = FolderRows.tree(u)
    ref_at = fn folder -> if folder == "", do: nil, else: Map.fetch!(tree, folder).id end
    {:ok, dek} = Crypto.get_dek(u)

    notes =
      for [id, ver, ct, nonce, ref] <-
            Repo.query!(
              "SELECT id, dek_version, folder_ciphertext, folder_nonce, folder_ref_id FROM notes " <>
                "WHERE vault_id = $1 AND kind = 'note' AND deleted_at IS NULL",
              [dump(v.id)]
            ).rows do
        id = Ecto.UUID.load!(id)
        aad = if Crypto.aad_bound?(ver), do: Crypto.aad_for_row(:notes, :folder, id), else: <<>>
        {:ok, folder} = Envelope.decrypt(ct, nonce, dek, aad)

        assert (ref && Ecto.UUID.load!(ref)) == ref_at.(folder),
               "note #{id} in #{inspect(folder)}"
      end

    atts =
      for [id, ver, ct, nonce, ref, stamp] <-
            Repo.query!(
              "SELECT id, dek_version, path_ciphertext, path_nonce, folder_ref_id, folder_ref_stamp " <>
                "FROM attachments WHERE vault_id = $1 AND deleted_at IS NULL",
              [dump(v.id)]
            ).rows do
        id = Ecto.UUID.load!(id)

        aad =
          if Crypto.aad_bound?(ver), do: Crypto.aad_for_row(:attachments, :path, id), else: <<>>

        {:ok, path} = Envelope.decrypt(ct, nonce, dek, aad)
        folder = Helpers.extract_folder(path)
        assert (ref && Ecto.UUID.load!(ref)) == ref_at.(folder), "attachment #{path}"
        assert stamp == nonce, "attachment #{path}: stale stamp"
      end

    length(notes) + length(atts)
  end

  test "control: with the triggers off, a write that sets only folder_hmac sets no reference",
       %{user: u, vault: v} do
    n = note!(u, v, "A/n.md")
    a_row = FolderRows.ref("notes", n.id)
    assert a_row
    {:ok, fk} = Crypto.dek_filter_key(u)

    # What the previous release's rename does: rewrite the hash only. With the
    # trigger on, this would NULL the reference (no row at "B").
    Repo.query!("UPDATE notes SET folder_hmac = $1 WHERE id = $2", [
      Crypto.hmac_field(fk, "B"),
      dump(n.id)
    ])

    assert FolderRows.ref("notes", n.id) == a_row
    %{rows: [[user]]} = app!(fn -> Repo.query!("SELECT current_user") end)
    assert user == "engram_app"
  end

  test "create: REST upsert, a nested new folder, the root, a CRDT genesis", %{user: u, vault: v} do
    note!(u, v, "Top.md")
    note!(u, v, "A/B/C/deep.md")
    note!(u, v, "A/shallow.md")
    attachment!(u, v, "A/B/pic.png")
    attachment!(u, v, "root.png")

    {:ok, _} = app!(fn -> Notes.genesis_crdt_note(u, v, Ecto.UUID.generate(), "G/born.md") end)

    assert assert_refs!(u, v) == 6
  end

  test "rename and move: one note, a batch of notes, a CRDT relocate, attachments",
       %{user: u, vault: v} do
    n1 = note!(u, v, "Src/one.md")
    n2 = note!(u, v, "Src/two.md")
    n3 = note!(u, v, "Src/three.md")
    attachment!(u, v, "Src/a.png")
    attachment!(u, v, "Src/b.png")

    {:ok, _} = app!(fn -> Notes.rename_note(u, v, "Src/one.md", "Dst/one.md") end)
    {:ok, _} = app!(fn -> Notes.batch_move_notes(u, v, [n2.id], {:path, "Batch/Deep"}) end)
    # The web app's rename: `crdt_create` of a live id at a new path.
    {:ok, _} = app!(fn -> Notes.genesis_crdt_note(u, v, n3.id, "Crdt/three.md") end)
    {:ok, _} = app!(fn -> Attachments.move_attachment(u, v, "Src/a.png", "Moved/a.png") end)
    {:ok, _} = app!(fn -> Attachments.batch_move(u, v, ["Src/b.png"], "BatchAtt") end)

    assert FolderRows.ref("notes", n1.id) == FolderRows.tree(u)["Dst"].id
    assert assert_refs!(u, v) == 5
  end

  test "folder rename cascade: plain, nested, and a merge into an existing folder",
       %{user: u, vault: v} do
    note!(u, v, "Old/n.md")
    note!(u, v, "Old/Sub/m.md")
    attachment!(u, v, "Old/Sub/p.png")
    note!(u, v, "Keep/k.md")
    note!(u, v, "Other/o.md")

    {:ok, _} = app!(fn -> Folders.rename(u, v, "Old", "New") end)
    assert assert_refs!(u, v) == 5

    # "Other" lands inside "Keep", which already has a row.
    {:ok, _} = app!(fn -> Folders.rename(u, v, "Other", "Keep/Other") end)
    assert assert_refs!(u, v) == 5

    # The merge: "New/Sub" onto "Was", whose row outlived its only note (a
    # target with live content of its own is refused).
    gone = note!(u, v, "Was/gone.md")
    :ok = app!(fn -> Notes.delete_note(u, v, gone.path) end)
    was = FolderRows.tree(u)["Was"].id
    {:ok, _} = app!(fn -> Folders.rename(u, v, "New/Sub", "Was") end)
    assert FolderRows.tree(u)["Was"].id == was
    assert assert_refs!(u, v) == 5
  end

  test "folder batch move by marker id", %{user: u, vault: v} do
    {:ok, marker} = app!(fn -> Notes.create_folder_marker(u, v, "Box") end)
    note!(u, v, "Box/n.md")
    attachment!(u, v, "Box/a.png")

    {:ok, _} = app!(fn -> Folders.batch_move(u, v, [marker.id], {:path, "Shelf"}) end)

    assert assert_refs!(u, v) == 2
  end

  test "restore: a recursive folder delete undone, after its folder rows were deleted",
       %{user: u, vault: v} do
    note!(u, v, "Docs/In/n.md")
    attachment!(u, v, "Docs/a.png")
    op = Ecto.UUID.generate()

    {:ok, %{notes: 1}} =
      app!(fn -> Folders.delete(u, v, "Docs", recursive: true, op_id: op) end)

    assert {:ok, %{notes: 1, attachments: 1}} = app!(fn -> Folders.restore_op(u, v, op) end)
    assert assert_refs!(u, v) == 2
  end
end
