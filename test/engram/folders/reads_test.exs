defmodule Engram.Folders.ReadsTest do
  # R9.5: folder rename / delete / move / listing read the folder's own rows by
  # `folder_ref_id`, not the whole vault. The stored paths stay authoritative, so
  # every route re-checks a row against its decrypted path, and a row the
  # backfill has not verified is read the old way.
  use Engram.DataCase, async: false

  import Engram.RlsCase

  alias Engram.{
    Attachments,
    Crypto,
    DataMigrations,
    Folders,
    Notes,
    QueryPlan,
    QueryRecorder,
    Repo
  }

  alias Engram.DataMigrations.FolderTable
  alias Engram.FolderRows
  alias Engram.Search.NoteFilter

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

    # The restore's own stamp: a row that was already stale when it was
    # deleted (the previous release moved it, then it went to the trash) comes
    # back re-pointed and stamped, not left for the drain.
    test "restore stamps a row that was stale when it was deleted", %{user: u, vault: v} do
      att = put_att(u, v, "P/a.png")
      op = Ecto.UUID.generate()
      assert {:ok, _} = Folders.delete(u, v, "P", recursive: true, op_id: op)

      Repo.query!(
        "UPDATE attachments SET folder_ref_id = NULL, folder_ref_stamp = NULL WHERE id = $1",
        [Ecto.UUID.dump!(att.id)]
      )

      assert {:ok, %{attachments: 1}} = Folders.restore_op(u, v, op)
      assert stale_count() == 0
      assert FolderRows.ref("attachments", att.id) == FolderRows.tree(u)["P"].id
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

  # R9.5 step 3: the folder readers take a note's folder from `folder_ref_id`,
  # not from `folder_hmac`. A note with no reference yet (the drift the drain
  # heals, `notes_unresolved_folder`) is read by its decrypted folder, so it
  # never leaves a listing, even for the drain's window.
  describe "readers take the folder from the reference" do
    defp dump(id), do: Ecto.UUID.dump!(id)

    defp hash(u, folder) do
      {:ok, fk} = Crypto.dek_filter_key(u)
      Crypto.hmac_field(fk, folder)
    end

    # The rotation case: the hash names "A", the reference (and the envelope)
    # say "B". The hash write fires `notes_set_folder_ref` (which re-derives
    # the reference from it), so the reference is written back after it.
    defp hash_says_a!(u, n) do
      Repo.query!("UPDATE notes SET folder_hmac = $1 WHERE id = $2", [hash(u, "A"), dump(n.id)])

      Repo.query!("UPDATE notes SET folder_ref_id = $1 WHERE id = $2", [
        dump(FolderRows.tree(u)["B"].id),
        dump(n.id)
      ])
    end

    # Drift: a non-root note with no reference (only the reference column is
    # written, so no notes trigger fires).
    defp unref!(n),
      do: Repo.query!("UPDATE notes SET folder_ref_id = NULL WHERE id = $1", [dump(n.id)])

    defp page_ids(u, v, folder) do
      {:ok, %{notes: notes}} = Notes.list_notes_in_folder_page(u, v, folder)
      notes |> Enum.map(& &1.id) |> Enum.sort()
    end

    defp counts(u, v) do
      {:ok, counts} = Notes.list_folders_with_counts(u, v)
      Map.new(counts, &{&1.folder, &1.count})
    end

    defp filter(u, v, f, within) do
      {:ok, {:ids, ids}} = NoteFilter.resolve(u, v, f, within: within)
      Enum.sort(ids)
    end

    defp seed(u, v) do
      put_note(u, v, "A/a.md")
      n = put_note(u, v, "B/n.md")
      put_note(u, v, "X/x.md")
      root = put_note(u, v, "root.md")
      {n, root}
    end

    test "hash names A, reference names B: every reader says B", %{user: u, vault: v} do
      {n, root} = seed(u, v)
      hash_says_a!(u, n)

      assert n.id in page_ids(u, v, "B")
      refute n.id in page_ids(u, v, "A")
      assert counts(u, v)["B"] == 1 and counts(u, v)["A"] == 1

      ids = [n.id, root.id]
      assert filter(u, v, %{folder: "B"}, ids) == [n.id]
      assert filter(u, v, %{not: %{folder: "B"}}, ids) == [root.id]
      assert filter(u, v, %{folder: "A"}, ids) == []

      # X -> B collides with B/n.md, which only the reference places in B.
      assert {:error, :conflict} = Notes.rename_folder(u, v, "X", "B")
    end

    # A non-root note with no reference: each reader still places it, by its
    # decrypted folder. One test per reader, so each is red without the
    # fallback.
    defp drifted(u, v) do
      {n, root} = seed(u, v)
      unref!(n)
      {n, root}
    end

    test "drift: the listing page", %{user: u, vault: v} do
      {n, root} = drifted(u, v)
      assert n.id in page_ids(u, v, "B")
      # Control: it is not taken for a root note.
      refute n.id in page_ids(u, v, "")
      assert root.id in page_ids(u, v, "")
    end

    test "drift: the counts", %{user: u, vault: v} do
      drifted(u, v)
      assert counts(u, v) |> Map.take(["", "B"]) == %{"" => 1, "B" => 1}
    end

    test "drift: the note filter and its complement", %{user: u, vault: v} do
      {n, root} = drifted(u, v)
      ids = [n.id, root.id]
      assert filter(u, v, %{folder: "B"}, ids) == [n.id]
      assert filter(u, v, %{not: %{folder: "B"}}, ids) == [root.id]
    end

    test "drift: the rename target check", %{user: u, vault: v} do
      drifted(u, v)
      assert {:error, :conflict} = Notes.rename_folder(u, v, "X", "B")
    end

    test "drift: the folders implied by notes", %{user: u, vault: v} do
      drifted(u, v)
      assert {:ok, folders} = Notes.list_folders_implied_by_notes(u, v)
      assert "B" in folders
    end

    test "drift: the cascade scan and a recursive delete", %{user: u, vault: v} do
      {n, _root} = drifted(u, v)
      assert {:ok, rows} = Notes.scan_folders(u, v, ["B"])
      assert n.id in Enum.map(rows, & &1.id)
      assert {:ok, %{notes: 1}} = Folders.delete(u, v, "B", recursive: true)
    end

    test "control: the counts equal the listings (#728) with drift and a moved hash", ctx do
      %{user: u, vault: v} = ctx
      {n, _root} = seed(u, v)
      hash_says_a!(u, n)
      unref!(put_note(u, v, "B/Deep/d.md"))

      for {folder, count} <- counts(u, v),
          do: assert(length(page_ids(u, v, folder)) == count, folder)
    end

    # The #2466 review's probes (H1, H2): a folder row that dies under its
    # content must not strand it. `folders_release_refs` NULLs the reference,
    # so the note is drift and the cascade reads it.
    defp kill_row!(u, path),
      do:
        Repo.query!("UPDATE folders SET deleted_at = now() WHERE id = $1", [
          dump(FolderRows.tree(u)[path].id)
        ])

    test "probe: a note whose row died moves with a rename of its folder", %{user: u, vault: v} do
      put_note(u, v, "Target/n1.md")
      lost = put_note(u, v, "Target/lost.md")
      put_note(u, v, "Gone/x.md")

      Repo.query!("UPDATE notes SET folder_ref_id = $1 WHERE id = $2", [
        dump(FolderRows.tree(u)["Gone"].id),
        dump(lost.id)
      ])

      kill_row!(u, "Gone")
      verified!()

      assert {:ok, _} = Folders.rename(u, v, "Target", "Renamed")
      {:ok, rows} = Notes.scan_folders(u, v, ["Renamed"])
      assert "Renamed/lost.md" in Enum.map(rows, & &1.path)
    end

    test "probe: a note under a retired row is deleted by a recursive delete", ctx do
      %{user: u, vault: v} = ctx
      put_note(u, v, "Src/n.md")
      kill_row!(u, "Src")
      verified!()

      assert {:ok, %{notes: 1}} = Folders.delete(u, v, "Src", recursive: true)
    end

    test "probe: a marker whose rows died is cleared", %{user: u, vault: v} do
      {:ok, _} = Notes.create_folder_marker(u, v, "F/Sub")
      kill_row!(u, "F/Sub")
      kill_row!(u, "F")
      verified!()

      assert {:ok, _} = Folders.delete(u, v, "F", recursive: true)

      assert %{rows: [[0]]} =
               Repo.query!(
                 "SELECT count(*) FROM notes WHERE vault_id = $1 AND kind = 'folder' AND deleted_at IS NULL",
                 [dump(v.id)]
               )
    end
  end

  # Each new statement, as the app role sends it: an index read, never a scan
  # of the vault's notes or attachments.
  describe "plans" do
    defp plans(fun, table) do
      {_, queries} = QueryRecorder.record(fun)

      for sql <- QueryPlan.reading(queries, table),
          do:
            {sql,
             QueryPlan.generic_plan(sql,
               analyze: [table],
               fresh: true,
               bitmapscan: false,
               all_visible: true
             )}
    end

    defp assert_index!(sql_plans, pattern, index) do
      matching = for {sql, plan} <- sql_plans, sql =~ pattern, do: plan
      assert matching != [], "no statement matches #{inspect(pattern)}"

      for plan <- matching do
        assert plan =~ index, plan
        refute plan =~ ~r/Seq Scan on (notes|attachments)/, plan
      end
    end

    # Real statistics: B is a small part of the vault, as a folder is.
    test "drift, listing page, counts, target check and filter", %{user: u, vault: v} do
      for i <- 1..150, do: put_note(u, v, "F#{rem(i, 75)}/n#{i}.md")
      put_note(u, v, "B/n.md")
      put_note(u, v, "root.md")

      all =
        plans(
          fn ->
            Notes.list_notes_in_folder_page(u, v, "B")
            Notes.list_notes_in_folder_page(u, v, "")
            Notes.list_folders_with_counts(u, v)
            Notes.rename_folder(u, v, "Q", "B")
            NoteFilter.resolve(u, v, %{folder: "B"})
          end,
          "notes"
        )

      assert_index!(all, ~r/octet_length\(.*\) > 16/, "notes_unresolved_folder")
      assert_index!(all, ~r/GROUP BY .*folder_ref_id/s, "notes_folder_ref_live")
      # The page fetches the row, so either reference index serves it.
      assert_index!(all, ~r/folder_ref_id" = (ANY|\$)/, "using notes_folder_ref")
      # The root page: a NULL reference that is not drift.
      assert_index!(all, ~r/coalesce\(octet_length/, "using notes_folder_ref")
    end

    test "the scan's marker arm and the attachments' stale arm", %{user: u, vault: v} do
      put_note(u, v, "Target/n.md")
      put_att(u, v, "Target/a.png")
      fun = fn -> Folders.delete(u, v, "Target", recursive: true) end

      assert_index!(plans(fun, "notes"), ~r/'folder'.*exists/is, "notes_user_vault_folder_marker")
      assert_index!(plans(fun, "attachments"), "IS DISTINCT FROM", "attachments_folder_ref_stale")
    end
  end

  # Under FORCE RLS as `engram_app`: every new read returns the tenant's rows
  # and nothing of another tenant's, whatever ids it is handed.
  describe "RLS" do
    test "the readers see the tenant's drift and references", %{user: u, vault: v} do
      {n, _root} = {put_note(u, v, "B/n.md"), put_note(u, v, "root.md")}
      d = put_note(u, v, "B/d.md")
      Repo.query!("UPDATE notes SET folder_ref_id = NULL WHERE id = $1", [dump(d.id)])

      {:returned, {page, drift}} =
        as_prod_role(fn ->
          Repo.with_tenant!(u.id, fn ->
            {:ok, dek} = Crypto.get_dek(u)
            {:ok, %{notes: page}} = Notes.list_notes_in_folder_page(u, v, "B")
            {page, Notes.drift_note_folders(u, v, dek)}
          end)
        end)

      assert page |> Enum.map(& &1.id) |> Enum.sort() == Enum.sort([n.id, d.id])
      assert drift == {[{d.id, "B"}], 0}
    end

    test "control: another tenant reading this vault's ids gets zero rows", %{user: u, vault: v} do
      put_note(u, v, "B/n.md")
      d = put_note(u, v, "B/d.md")
      Repo.query!("UPDATE notes SET folder_ref_id = NULL WHERE id = $1", [dump(d.id)])
      {:ok, other} = Engram.Fixtures.user_with_dek_fixture()
      ids = [FolderRows.tree(u)["B"].id]

      # The same statements, user 1's vault and user 1's ids, under user 2's
      # tenant: RLS, not the WHERE clause, has to hide them.
      {:returned, {by_ref, drift}} =
        as_prod_role(fn ->
          Repo.with_tenant!(other.id, fn ->
            {Repo.all(
               from(n in Engram.Notes.Note,
                 where: n.vault_id == ^v.id and n.kind == "note" and n.folder_ref_id in ^ids,
                 select: n.id
               )
             ), Enum.map(Repo.all(Notes.drift_query(u, v)), & &1.id)}
          end)
        end)

      assert {by_ref, drift} == {[], []}

      # The real readers, as user 2 on user 1's vault: nothing either.
      {:returned, {page, placed}} =
        as_prod_role(fn ->
          {:ok, %{notes: page}} = Notes.list_notes_in_folder_page(other, v, "B")
          {:ok, dek} = Crypto.get_dek(other)
          {page, Repo.with_tenant!(other.id, fn -> Notes.drift_note_folders(other, v, dek) end)}
        end)

      assert {page, placed} == {[], {[], 0}}
      # And the superuser does see them: the fixture is not empty.
      assert Repo.with_tenant!(u.id, fn ->
               Enum.map(Repo.all(Notes.drift_query(u, v)), & &1.id)
             end) == [d.id]
    end
  end

  # The #2485 review (MED-1, MED-2): a heal (the drain giving a drift note
  # its folder row) that commits between two of a reader's statements must
  # not hide the note. The heal runs right after the reader's first
  # `folders` statement inside `frame`, in the reader's own transaction:
  # what a commit landing between the two statements looks like to the next.
  describe "a heal between a reader's statements" do
    defp in_frame?(frame) do
      {:current_stacktrace, stack} = Process.info(self(), :current_stacktrace)

      Enum.any?(stack, fn {mod, fun, _, _} ->
        mod == Notes and String.contains?(Atom.to_string(fun), frame)
      end)
    end

    defp heal_after_folder_read(frame, heal, fun) do
      pid = self()
      id = "heal-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        id,
        [:engram, :repo, :query],
        fn _, _, meta, _ ->
          if self() == pid and meta[:source] == "folders" and not Process.get(:healed, false) and
               in_frame?(frame) do
            Process.put(:healed, true)
            heal.()
          end
        end,
        nil
      )

      try do
        result = fun.()
        assert Process.get(:healed), "the heal never ran"
        result
      after
        :telemetry.detach(id)
        Process.delete(:healed)
      end
    end

    # `A/C/n.md` with no row at A/C (hard-deleted: the FK NULLs the
    # reference), so the note is drift. The heal re-creates the row and points
    # the note at it, as `FolderTable` does.
    defp drifted_deep!(u, v) do
      n = put_note(u, v, "A/C/n.md")
      Repo.query!("DELETE FROM folders WHERE id = $1", [dump(FolderRows.tree(u)["A/C"].id)])
      assert FolderRows.ref("notes", n.id) == nil

      heal = fn ->
        {:ok, row} = Folders.Rows.ensure(u, v.id, "A/C")

        Repo.query!("UPDATE notes SET folder_ref_id = $1 WHERE id = $2", [
          dump(row),
          dump(n.id)
        ])
      end

      {n, heal}
    end

    test "the listing page", %{user: u, vault: v} do
      {n, heal} = drifted_deep!(u, v)

      ids =
        heal_after_folder_read("directly_in", heal, fn -> page_ids(u, v, "A/C") end)

      assert n.id in ids
    end

    test "a rename moves the note with its folder", %{user: u, vault: v} do
      {n, heal} = drifted_deep!(u, v)

      heal_after_folder_read("scan_with_drift", heal, fn ->
        assert {:ok, _} = Folders.rename(u, v, "A", "Z")
      end)

      {:ok, moved} = Notes.get_note_by_id(u, v, n.id)
      assert moved.path == "Z/C/n.md"
      assert FolderRows.ref("notes", n.id) == FolderRows.tree(u)["Z/C"].id
    end

    test "a recursive delete deletes it", %{user: u, vault: v} do
      {_n, heal} = drifted_deep!(u, v)

      heal_after_folder_read("scan_with_drift", heal, fn ->
        assert {:ok, %{notes: 1}} = Folders.delete(u, v, "A", recursive: true)
      end)
    end

    # MED-1: the counts read the groups, the drift and the markers in one
    # statement (one snapshot), so no heal can land between them.
    test "the counts read the vault's notes in ONE statement", %{user: u, vault: v} do
      put_note(u, v, "B/n.md")
      unref!(put_note(u, v, "B/d.md"))

      {_, queries} =
        QueryRecorder.record(fn ->
          Repo.with_tenant!(u.id, fn -> Notes.raw_folder_count_rows(u, v) end)
        end)

      assert [one] = QueryPlan.reading(queries, "notes")
      assert one =~ "GROUP BY" and one =~ "octet_length"
    end
  end

  # LOW-1: one drift envelope that will not open is left out of the counts
  # (and logged), as the listing leaves it out; the rest is served.
  test "an undecryptable drift envelope is skipped by counts and listing", %{user: u, vault: v} do
    put_note(u, v, "A/a.md")
    bad = put_note(u, v, "B/n.md")
    unref!(bad)

    Repo.query!("UPDATE notes SET folder_ciphertext = $1 WHERE id = $2", [
      :crypto.strong_rand_bytes(40),
      dump(bad.id)
    ])

    assert %{"A" => 1} = counts(u, v)
    refute Map.has_key?(counts(u, v), "B")
    assert page_ids(u, v, "B") == []
  end
end
