defmodule Engram.Folders.FolderRefReleaseTest do
  # A folder reference never names a deleted folder row (#2466 review, H1 and
  # H2). Folder rows are soft-deleted, so the `ON DELETE SET NULL` foreign key
  # never fires for them; the `folders_release_refs` trigger does its job on
  # the soft delete, and a NULL lands in the drift indexes the drain already
  # reads. A folder row a live marker names is not soft-deleted at all.
  # `FolderTable` version 3 heals the rows written before both.
  use Engram.DataCase, async: false

  alias Engram.Attachments
  alias Engram.Bookkeeping.Drain
  alias Engram.DataMigrations.FolderTable
  alias Engram.FolderRows
  alias Engram.Folders.Rows
  alias Engram.Notes
  alias Engram.QueryPlan
  alias Engram.QueryRecorder
  alias Engram.Repo

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp dump(id), do: Ecto.UUID.dump!(id)

  defp note!(u, v, path) do
    {:ok, n} =
      Notes.upsert_note(u, v, %{"path" => path, "content" => "# T\n\nbody"}, actor: "api")

    n
  end

  defp attachment!(u, v, path) do
    {:ok, a} =
      Attachments.upsert_attachment(u, v, %{
        "path" => path,
        "content_base64" => Base.encode64("bytes of " <> path)
      })

    a
  end

  defp kill_row!(id),
    do: Repo.query!("UPDATE folders SET deleted_at = now() WHERE id = $1", [dump(id)])

  defp stamp(att_id) do
    %{rows: [[stamp, nonce]]} =
      Repo.query!("SELECT folder_ref_stamp, path_nonce FROM attachments WHERE id = $1", [
        dump(att_id)
      ])

    {stamp, nonce}
  end

  defp drift_users, do: Drain.candidates(:folder)

  describe "soft-deleting a folder row releases the references to it" do
    # H1: red on main, where the note kept the dead row's id and no drift
    # index saw it.
    test "a live note's reference becomes NULL and the drain finds its user", %{
      user: u,
      vault: v
    } do
      lost = note!(u, v, "Gone/lost.md")
      row = FolderRows.ref("notes", lost.id)
      assert row
      refute u.id in drift_users()

      kill_row!(row)

      assert FolderRows.ref("notes", lost.id) == nil
      assert u.id in drift_users()
    end

    # The attachments half: NULL alone is not drift for an attachment (its
    # drift test is the stamp), so the stamp goes too. Red on main.
    test "a live attachment's reference and stamp are cleared, so the drain finds it", %{
      user: u,
      vault: v
    } do
      att = attachment!(u, v, "Gone/a.png")
      row = FolderRows.ref("attachments", att.id)
      assert row
      {stamp, nonce} = stamp(att.id)
      assert stamp == nonce
      refute u.id in drift_users()

      kill_row!(row)

      assert FolderRows.ref("attachments", att.id) == nil
      assert {nil, _} = stamp(att.id)
      assert u.id in drift_users()
    end

    test "the drain heals the released reference back to a live row", %{user: u, vault: v} do
      :ok = Engram.DataMigrations.mark_done(FolderTable.name(), FolderTable.version())
      lost = note!(u, v, "Gone/lost.md")
      att = attachment!(u, v, "Gone/a.png")
      kill_row!(FolderRows.ref("notes", lost.id))

      Drain.run()

      live = FolderRows.tree(u)["Gone"].id
      assert FolderRows.ref("notes", lost.id) == live
      assert FolderRows.ref("attachments", att.id) == live
      refute u.id in drift_users()
    end

    # Controls: what the trigger must not touch.
    test "a deleted note keeps its reference (a restore re-resolves it)", %{user: u, vault: v} do
      trashed = note!(u, v, "Gone/trashed.md")
      row = FolderRows.ref("notes", trashed.id)
      Repo.query!("UPDATE notes SET deleted_at = now() WHERE id = $1", [dump(trashed.id)])

      kill_row!(row)

      assert FolderRows.ref("notes", trashed.id) == row
    end

    test "another folder's references, a rename and a revive are left alone", %{
      user: u,
      vault: v
    } do
      kept = note!(u, v, "Kept/n.md")
      gone = note!(u, v, "Gone/n.md")
      kept_row = FolderRows.ref("notes", kept.id)
      gone_row = FolderRows.ref("notes", gone.id)

      # An update that is not a live-to-deleted flip fires nothing.
      Repo.query!("UPDATE folders SET updated_at = now() WHERE id = $1", [dump(kept_row)])
      kill_row!(gone_row)
      assert FolderRows.ref("notes", kept.id) == kept_row

      # Re-deleting an already deleted row (a second delete) is not a flip either.
      Repo.query!("UPDATE notes SET folder_ref_id = $2 WHERE id = $1", [
        dump(gone.id),
        dump(gone_row)
      ])

      Repo.query!("UPDATE folders SET deleted_at = now() WHERE id = $1", [dump(gone_row)])
      assert FolderRows.ref("notes", gone.id) == gone_row
    end

    test "a merge rename leaves every moved note on the surviving row", %{user: u, vault: v} do
      moved = note!(u, v, "Src/n.md")
      src = FolderRows.ref("notes", moved.id)
      # An emptied folder keeps its row: the rename then folds Src into it.
      gone = note!(u, v, "Dst/m.md")
      keeper = FolderRows.ref("notes", gone.id)
      Repo.query!("UPDATE notes SET deleted_at = now() WHERE id = $1", [dump(gone.id)])

      assert {:ok, _} = Engram.Folders.rename(u, v, "Src", "Dst")

      assert FolderRows.row(src).deleted_at
      assert FolderRows.ref("notes", moved.id) == keeper
      refute u.id in drift_users()
    end
  end

  describe "a folder row a live marker names is not soft-deleted" do
    # H2: red on main, where `live_content_folders/1` counted notes and
    # attachments only, so a marker committed after a delete's scan was left
    # with no row (undeletable, unrenamable). Behind the vault lock both
    # writers take, the marker is either seen here or created after.
    test "the marker's row and its ancestors stay", %{user: u, vault: v} do
      {:ok, _} = Notes.create_folder_marker(u, v, "F/Sub")
      t = FolderRows.tree(u)

      assert Repo.with_tenant!(u.id, fn -> Rows.soft_delete(u, v.id, ["F"], nil) end) == 0
      assert FolderRows.row(t["F/Sub"].id).deleted_at == nil
      assert FolderRows.row(t["F"].id).deleted_at == nil
    end

    test "a recursive delete still removes the marker and its rows", %{user: u, vault: v} do
      {:ok, _} = Notes.create_folder_marker(u, v, "F/Sub")
      t = FolderRows.tree(u)

      assert {:ok, _} = Engram.Folders.delete(u, v, "F", recursive: true)
      assert FolderRows.row(t["F/Sub"].id).deleted_at
      assert FolderRows.row(t["F"].id).deleted_at
    end

    test "a deleted marker does not keep its row", %{user: u, vault: v} do
      {:ok, m} = Notes.create_folder_marker(u, v, "F")
      Repo.query!("UPDATE notes SET deleted_at = now() WHERE id = $1", [dump(m.id)])

      assert Repo.with_tenant!(u.id, fn -> Rows.soft_delete(u, v.id, ["F"], nil) end) == 1
    end
  end

  describe "FolderTable version 3 heals what was written before" do
    # Red on main: version 2 walks only attachments whose stamp is stale, and
    # this one's stamp is current while its reference names a dead row.
    test "an attachment whose current reference names a dead row is re-pointed", %{
      user: u,
      vault: v
    } do
      att = attachment!(u, v, "P/a.png")
      live = FolderRows.ref("attachments", att.id)
      dead = FolderRows.insert!(u, v, <<0::256>>, deleted_at: ~U[2026-11-01 00:00:00Z])

      Repo.query!("UPDATE attachments SET folder_ref_id = $2 WHERE id = $1", [
        dump(att.id),
        dump(dead)
      ])

      assert {:more, _} = FolderTable.run_pass(user_ids: [u.id])
      assert FolderRows.ref("attachments", att.id) == live
      assert {s, s} = stamp(att.id)
      assert :done = FolderTable.run_pass(user_ids: [u.id])
    end

    test "a note whose reference names a dead row is re-pointed", %{user: u, vault: v} do
      n = note!(u, v, "P/n.md")
      live = FolderRows.ref("notes", n.id)
      dead = FolderRows.insert!(u, v, <<0::256>>, deleted_at: ~U[2026-11-01 00:00:00Z])
      Repo.query!("UPDATE notes SET folder_ref_id = $2 WHERE id = $1", [dump(n.id), dump(dead)])

      assert {:more, _} = FolderTable.run_pass(user_ids: [u.id])
      assert FolderRows.ref("notes", n.id) == live
    end

    test "a live marker whose rows died gets a live row again", %{user: u, vault: v} do
      {:ok, _} = Notes.create_folder_marker(u, v, "F/Sub")
      t = FolderRows.tree(u)
      kill_row!(t["F/Sub"].id)
      kill_row!(t["F"].id)
      assert FolderRows.tree(u) == %{}

      assert {:more, _} = FolderTable.run_pass(user_ids: [u.id])
      assert %{"F" => _, "F/Sub" => %{explicit: true}} = FolderRows.tree(u)
    end
  end

  describe "plans" do
    setup %{user: u, vault: v} do
      for i <- 1..100, do: note!(u, v, "Clean#{rem(i, 5)}/n#{i}.md")
      # Real statistics on attachments too: on an empty table every index ties.
      for i <- 1..40, do: attachment!(u, v, "Clean#{rem(i, 5)}/a#{i}.png")
      :ok
    end

    # The trigger's statements, read back from the installed function (so the
    # test plans what runs, not a copy), with NEW's fields as parameters.
    test "the trigger's updates use the reference indexes, not a table scan" do
      %{rows: [[src]]} =
        Repo.query!("SELECT prosrc FROM pg_proc WHERE proname = 'folders_release_refs'")

      updates =
        ~r/UPDATE\s+public\.(\w+)\s.*?;/s
        |> Regex.scan(src)
        |> Enum.map(fn [sql, table] ->
          {table,
           sql
           |> String.trim_trailing(";")
           |> String.replace("public.", "")
           |> String.replace("NEW.vault_id", "$1::uuid")
           |> String.replace("NEW.id", "$2::uuid")}
        end)

      assert Enum.map(updates, &elem(&1, 0)) == ["notes", "attachments"]

      for {table, sql} <- updates do
        plan = QueryPlan.generic_plan(sql, analyze: [table], fresh: true)
        assert plan =~ "#{table}_folder_ref", plan
        refute plan =~ "Seq Scan on #{table}", plan
      end
    end

    # The foreign keys' own `ON DELETE SET NULL` (a hard delete: a vault purge
    # or a pruning pass) reaches notes and attachments through
    # `notes_folder_ref` / `attachments_folder_ref`, not a table scan per
    # deleted folder. Counted from the transaction's own scan statistics, with
    # seq scans off: the question is whether an index CAN serve the RI query.
    test "a hard folder delete nulls references through an index, no seq scan", %{
      user: u,
      vault: v
    } do
      n = note!(u, v, "Hard/n.md")
      a = attachment!(u, v, "Hard/a.png")
      row = FolderRows.ref("notes", n.id)

      scans = fn ->
        %{rows: rows} =
          Repo.query!(
            "SELECT relname, seq_scan, coalesce(idx_scan, 0) FROM pg_stat_xact_user_tables " <>
              "WHERE relname IN ('notes', 'attachments')"
          )

        Map.new(rows, fn [t, seq, idx] -> {t, {seq, idx}} end)
      end

      Repo.query!("SET LOCAL enable_seqscan = off")
      before = scans.()
      Repo.query!("DELETE FROM folders WHERE id = $1", [dump(row)])
      after_ = scans.()

      assert FolderRows.ref("notes", n.id) == nil
      assert FolderRows.ref("attachments", a.id) == nil

      for t <- ~w(notes attachments) do
        {seq0, idx0} = Map.get(before, t, {0, 0})
        {seq1, idx1} = after_[t]
        assert seq1 == seq0, "#{t}: the SET NULL action seq-scanned"
        assert idx1 > idx0, "#{t}: the SET NULL action used no index"
      end
    end

    # What `NoteFilter.folder/2` will send once it reads references: an
    # index-only scan of the covering index, the match and its complement.
    test "a folder filter on references is an index-only scan of notes_folder_ref_live" do
      for sql <- [
            "SELECT id FROM notes WHERE vault_id = $1 AND deleted_at IS NULL AND kind = 'note' " <>
              "AND folder_ref_id = ANY($2::uuid[])",
            "SELECT id FROM notes WHERE vault_id = $1 AND deleted_at IS NULL AND kind = 'note' " <>
              "AND NOT (folder_ref_id IS NOT NULL AND folder_ref_id = ANY($2::uuid[]))"
          ] do
        plan =
          QueryPlan.generic_plan(sql,
            analyze: ~w(notes),
            fresh: true,
            bitmapscan: false,
            all_visible: true
          )

        assert plan =~ "Index Only Scan using notes_folder_ref_live", plan
      end
    end

    test "soft_delete's marker lookup is an index read", %{user: u, vault: v} do
      {:ok, _} = Notes.create_folder_marker(u, v, "Clean1/M")

      {_, queries} =
        QueryRecorder.record(fn ->
          Repo.with_tenant!(u.id, fn -> Rows.soft_delete(u, v.id, ["Clean1"], nil) end)
        end)

      [sql] = for sql <- QueryPlan.reading(queries, "notes"), sql =~ "'folder'", do: sql
      plan = QueryPlan.generic_plan(sql, analyze: ~w(notes), fresh: true)
      refute plan =~ "Seq Scan on notes", plan
    end

    test "the version 3 dead-reference step walks the user's folder rows", %{user: u} do
      {_, queries} = QueryRecorder.record(fn -> FolderTable.run_pass(user_ids: [u.id]) end)

      [sql] =
        for %{sql: sql} <- queries,
            sql =~ "UPDATE attachments",
            sql =~ "deleted_at IS NOT NULL",
            do: sql

      plan = QueryPlan.generic_plan(sql, analyze: ~w(attachments folders), fresh: true)
      refute plan =~ "Seq Scan on attachments", plan
      refute plan =~ "Seq Scan on folders", plan
    end
  end
end
