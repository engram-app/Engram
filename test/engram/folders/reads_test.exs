defmodule Engram.Folders.ReadsTest do
  # R9.5: folder rename / delete / move / listing read the folder's own rows by
  # `folder_ref_id`, not the whole vault. The stored paths stay authoritative, so
  # every route re-checks a row against its decrypted path, and a row the
  # backfill has not verified is read the old way.
  use Engram.DataCase, async: false

  alias Engram.{Attachments, DataMigrations, Folders, Notes, Repo}
  alias Engram.DataMigrations.FolderTable
  alias Engram.FolderRows

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    # Counts the rows `Attachments` decrypts, the oracle for "no whole-vault decrypt".
    test_pid = self()
    handler = "reads-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:engram, :crypto, :decrypt_batch],
      fn _event, %{count: count}, %{kind: kind}, _ ->
        if kind == :attachments, do: send(test_pid, {:decrypted_attachments, count})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    %{user: user, vault: vault}
  end

  defp put_att(user, vault, path) do
    {:ok, att} =
      Attachments.upsert_attachment(user, vault, %{
        "path" => path,
        "content_base64" => Base.encode64("bytes of " <> path)
      })

    att
  end

  defp put_note(user, vault, path) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => "# T\n\nbody"}, actor: "api")

    note
  end

  # Everything the backfill would have done is done: the ledger is closed.
  defp verified!, do: DataMigrations.mark_done(FolderTable.name(), FolderTable.version())

  # A task still on the previous release rewrote this attachment's path: it
  # may now carry no reference, or a stale one, and not this release's stamp.
  defp old_release_touch!(att, ref) do
    Repo.query!(
      "UPDATE attachments SET folder_ref_id = $2, folder_ref_stamp = NULL WHERE id = $1",
      [Ecto.UUID.dump!(att.id), ref && Ecto.UUID.dump!(ref)]
    )
  end

  defp drain_decrypts(total \\ 0) do
    receive do
      {:decrypted_attachments, n} -> drain_decrypts(total + n)
    after
      0 -> total
    end
  end

  defp live_paths(user, vault) do
    {:ok, metas} = Attachments.list_attachments(user, vault)
    metas |> Enum.map(& &1.path) |> Enum.sort()
  end

  defp seed_attachments!(user, vault) do
    in_target = [put_att(user, vault, "Target/a.png"), put_att(user, vault, "Target/Sub/b.png")]
    for i <- 1..10, do: put_att(user, vault, "Other/p#{i}.png")
    for i <- 1..3, do: put_att(user, vault, "root#{i}.png")
    in_target
  end

  describe "attachment folder operations decrypt only the target's attachments" do
    test "rename", %{user: u, vault: v} do
      seed_attachments!(u, v)
      verified!()
      drain_decrypts()

      assert {:ok, %{attachments: 2}} = Folders.rename(u, v, "Target", "Renamed")

      # Fails without the change: the whole vault (15 rows) was decrypted.
      assert drain_decrypts() == 2
      assert "Renamed/Sub/b.png" in live_paths(u, v)
      assert length(live_paths(u, v)) == 15
    end

    test "delete (refusal, then recursive)", %{user: u, vault: v} do
      seed_attachments!(u, v)
      verified!()
      drain_decrypts()

      assert {:error, {:not_empty, %{attachments: 2}}} = Folders.delete(u, v, "Target")
      assert drain_decrypts() == 2

      assert {:ok, %{attachments: 2}} = Folders.delete(u, v, "Target", recursive: true)
      assert drain_decrypts() == 2
      assert length(live_paths(u, v)) == 13
    end

    test "batch move", %{user: u, vault: v} do
      seed_attachments!(u, v)
      {:ok, %{folders: [%{id: marker}]}} = Notes.create_folder_markers(u, v, ["Target"])
      put_note(u, v, "Dest/n.md")
      verified!()
      drain_decrypts()

      assert {:ok, %{attachments: 2}} = Folders.batch_move(u, v, [marker], {:path, "Dest"})
      assert drain_decrypts() == 2
      assert "Dest/Target/Sub/b.png" in live_paths(u, v)
    end

    test "MCP list_folder (direct children, and the root)", %{user: u, vault: v} do
      seed_attachments!(u, v)
      verified!()
      drain_decrypts()

      assert {:ok, [%{path: "Target/a.png"}]} = Attachments.list_in_folder(u, v, "Target")
      assert drain_decrypts() == 1

      {:ok, root} = Attachments.list_in_folder(u, v, "")
      assert root |> Enum.map(& &1.path) |> Enum.sort() == ~w(root1.png root2.png root3.png)
      assert drain_decrypts() == 3
    end
  end

  describe "control: rows the backfill has not stamped resolve through the old path" do
    test "before the version 2 pass: NULL references are found by decrypting everything", ctx do
      %{user: u, vault: v} = ctx
      [a, b] = seed_attachments!(u, v)
      Repo.query!("UPDATE attachments SET folder_ref_id = NULL, folder_ref_stamp = NULL")
      drain_decrypts()

      assert {:ok, %{attachments: 2}} = Folders.rename(u, v, "Target", "Renamed")
      assert drain_decrypts() == 15
      paths = live_paths(u, v)
      assert "Renamed/a.png" in paths and "Renamed/Sub/b.png" in paths
      _ = {a, b}
    end

    # #2413: the stamp, not the ledger or a row's age, decides what is trusted.
    # The row's path is in Target; its reference names Other. Red before: the
    # stamp did not exist, so the reference was trusted by age.
    test "a reference whose stamp does not match the path is not trusted", ctx do
      %{user: u, vault: v} = ctx
      seed_attachments!(u, v)
      att = put_att(u, v, "Target/in.png")
      verified!()

      Repo.query!(
        "UPDATE attachments SET folder_ref_id = $2, folder_ref_stamp = '\\x00'::bytea WHERE id = $1",
        [Ecto.UUID.dump!(att.id), Ecto.UUID.dump!(FolderRows.tree(u)["Other"].id)]
      )

      drain_decrypts()
      assert {:ok, %{attachments: 3}} = Folders.rename(u, v, "Target", "Renamed")
      # The 2 trusted rows of Target + the 1 mismatched row, read by its path.
      assert drain_decrypts() == 3
      assert "Renamed/in.png" in live_paths(u, v)
    end

    test "control: the same wrong reference with a matching stamp is trusted", ctx do
      %{user: u, vault: v} = ctx
      seed_attachments!(u, v)
      att = put_att(u, v, "Target/in.png")

      Repo.query!(
        "UPDATE attachments SET folder_ref_id = $2, folder_ref_stamp = path_nonce WHERE id = $1",
        [Ecto.UUID.dump!(att.id), Ecto.UUID.dump!(FolderRows.tree(u)["Other"].id)]
      )

      assert {:ok, %{attachments: 2}} = Folders.rename(u, v, "Target", "Renamed")
      assert "Target/in.png" in live_paths(u, v)
    end
  end

  # #2413: every writer of a reference stamps it (`Rows.attachment_ref/2`),
  # so the drain's index stays empty in steady state.
  describe "every attachment writer stamps its reference" do
    defp stale_count do
      %{rows: [[n]]} =
        Repo.query!(
          "SELECT count(*) FROM attachments WHERE deleted_at IS NULL AND folder_ref_stamp IS DISTINCT FROM path_nonce"
        )

      n
    end

    test "upload, move, folder rename, delete and restore", %{user: u, vault: v} do
      put_att(u, v, "A/a.png")
      put_att(u, v, "A/B/b.png")
      put_att(u, v, "root.png")
      assert stale_count() == 0

      {:ok, _} = Attachments.move_attachment(u, v, "A/a.png", "C/a.png")
      assert stale_count() == 0

      assert {:ok, _} = Folders.rename(u, v, "A", "Z")
      assert stale_count() == 0

      op = Ecto.UUID.generate()
      assert {:ok, _} = Folders.delete(u, v, "Z", recursive: true, op_id: op)
      assert {:ok, %{attachments: 1}} = Folders.restore_op(u, v, op)
      assert stale_count() == 0
      assert "Z/B/b.png" in live_paths(u, v)
    end
  end

  describe "rollout: the previous release keeps writing after the backfill closed" do
    test "an upload it made (NULL reference) is still renamed with its folder", ctx do
      %{user: u, vault: v} = ctx
      seed_attachments!(u, v)
      late = put_att(u, v, "Target/late.png")
      verified!()
      old_release_touch!(late, nil)
      drain_decrypts()

      assert {:ok, %{attachments: 3}} = Folders.rename(u, v, "Target", "Renamed")

      # 2 trusted rows of the folder + the 1 unverified row, not the vault.
      assert drain_decrypts() == 3
      assert "Renamed/late.png" in live_paths(u, v)
    end

    test "a move it made INTO the folder (stale reference to the old one) moves with it", ctx do
      %{user: u, vault: v} = ctx
      seed_attachments!(u, v)
      mover = put_att(u, v, "Other/x.png")
      other_id = FolderRows.tree(u)["Other"].id
      {:ok, _} = Attachments.move_attachment(u, v, "Other/x.png", "Target/moved-in.png")
      verified!()
      # What the previous release leaves behind: new path, the old folder's id.
      old_release_touch!(mover, other_id)

      assert {:ok, %{attachments: 3}} = Folders.rename(u, v, "Target", "Renamed")
      assert "Renamed/moved-in.png" in live_paths(u, v)
    end

    test "a move it made (stale reference) is not dragged along by the old folder", ctx do
      %{user: u, vault: v} = ctx
      seed_attachments!(u, v)
      stale = put_att(u, v, "Other/moved-away.png")
      target_id = FolderRows.tree(u)["Target"].id
      verified!()
      # The previous release moved it out of Target: path changed, reference did not.
      old_release_touch!(stale, target_id)

      assert {:error, {:not_empty, %{attachments: 2}}} = Folders.delete(u, v, "Target")
      assert {:ok, %{attachments: 2}} = Folders.delete(u, v, "Target", recursive: true)
      assert "Other/moved-away.png" in live_paths(u, v)
    end
  end

  describe "notes" do
    test "scan_folders never opens the folder envelope of a resolved note elsewhere", ctx do
      %{user: u, vault: v} = ctx
      put_note(u, v, "Target/n1.md")
      put_note(u, v, "Target/Deep/n2.md")
      other = put_note(u, v, "Other/n3.md")
      {:ok, _} = Notes.create_folder_markers(u, v, ["Target/Empty"])

      # Corrupt the other folder's envelope. The old scan decrypted one envelope
      # per distinct folder in the vault and raised; reading by reference does not.
      Repo.query!("UPDATE notes SET folder_ciphertext = '\\x00' WHERE id = $1", [
        Ecto.UUID.dump!(other.id)
      ])

      assert {:ok, rows} = Notes.scan_folders(u, v, ["Target"])

      assert rows |> Enum.map(& &1.folder) |> Enum.sort() == [
               "Target",
               "Target/Deep",
               "Target/Empty"
             ]

      assert Enum.count(rows, &(&1.kind == "folder")) == 1
    end

    test "control: a note with no reference (written by the previous release) is found", ctx do
      %{user: u, vault: v} = ctx
      put_note(u, v, "Target/n1.md")
      old = Engram.Fixtures.insert_note!(u, v, %{path: "Target/Fresh/old.md", content: "x"})
      assert FolderRows.ref("notes", old.id) == nil

      {:ok, rows} = Notes.scan_folders(u, v, ["Target"])
      assert "Target/Fresh" in Enum.map(rows, & &1.folder)
    end

    test "control: an old-release marker with no folder row is found", ctx do
      %{user: u, vault: v} = ctx
      put_note(u, v, "Target/n1.md")
      {:ok, %{folders: [%{id: marker}]}} = Notes.create_folder_markers(u, v, ["Target/Gone"])
      Repo.query!("DELETE FROM folders WHERE id = $1", [Ecto.UUID.dump!(marker)])

      {:ok, rows} = Notes.scan_folders(u, v, ["Target"])
      assert Enum.any?(rows, &(&1.kind == "folder" and &1.folder == "Target/Gone"))
    end

    test "list_folders and the counts read folder rows, and agree with each other", ctx do
      %{user: u, vault: v} = ctx
      n1 = put_note(u, v, "A/B/n1.md")
      n2 = put_note(u, v, "A/B/n2.md")
      put_note(u, v, "A/n3.md")
      put_note(u, v, "root.md")
      {:ok, _} = Notes.create_folder_markers(u, v, ["M/Only", "A"])
      Engram.Fixtures.insert_note!(u, v, %{path: "OR/old.md", content: "x"})

      # Corrupt the folder envelope of every resolved note in A/B: the count
      # must not need them (the old grouped read opened one of them).
      Repo.query!("UPDATE notes SET folder_ciphertext = '\\x00' WHERE id = ANY($1)", [
        [Ecto.UUID.dump!(n1.id), Ecto.UUID.dump!(n2.id)]
      ])

      {:ok, counts} = Notes.list_folders_with_counts(u, v)

      assert Map.new(counts, &{&1.folder, &1.count}) == %{
               "" => 1,
               "A" => 1,
               "A/B" => 2,
               "M/Only" => 0,
               "OR" => 1
             }

      {:ok, folders} = Notes.list_folders(u, v)
      assert folders == ["A", "A/B", "M/Only", "OR"]
    end
  end
end
