defmodule Engram.Folders.FolderRefReleaseTest do
  # A folder reference never names a deleted folder row (#2466 review, H1 and
  # H2). Folder rows are soft-deleted, so the `ON DELETE SET NULL` foreign key
  # never fires for them; the `folders_release_refs` trigger does its job on
  # the soft delete, and a NULL lands in the drift indexes the drain already
  # reads. A folder row a live marker names is not soft-deleted at all.
  # `FolderTable` version 3 heals the rows written before both.
  #
  # Every write that fires the trigger runs as the prod-like `engram_app`
  # (no SUPERUSER, no BYPASSRLS) under FORCE RLS, through `Engram.RlsCase`:
  # the suite's superuser would see every row whatever the tenant
  # (docs/context/rls-enforcement-testing-traps.md).
  use Engram.DataCase, async: false

  import Engram.RlsCase

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

  # What COMMIT would run that a sandboxed test never reaches: every pending
  # deferred constraint or trigger, fired here. Called where prod's COMMIT
  # runs, after `with_tenant` has exited (role back to the session role,
  # tenant cleared), so a deferred trigger that cannot see the tenant's rows
  # at commit fails these tests (it did, #2468 delta review H1). A no-op for
  # the immediate trigger.
  defp commit!, do: Repo.query!("SET CONSTRAINTS ALL IMMEDIATE")

  # `fun` as a request does it: `engram_app`, inside the tenant's block, then
  # the commit point outside it. Returns `fun`'s value.
  defp app_write!(u, fun) do
    as_prod_role_committing(fn ->
      result = Repo.with_tenant!(u.id, fun)
      commit!()
      result
    end)
  end

  # A REST folder call as prod runs it: `engram_app`, NO tenant around it
  # (`Folders.atomic/1` opens its outer transaction with none; the legs open
  # their own tenant blocks), then the commit point.
  defp rest_call!(fun) do
    as_prod_role_committing(fn ->
      result = fun.()
      commit!()
      result
    end)
  end

  defp kill_row!(u, id),
    do:
      app_write!(u, fn ->
        Repo.query!("UPDATE folders SET deleted_at = now() WHERE id = $1", [dump(id)])
      end)

  # A folder at `path` whose only note was deleted: its row stays, so a
  # rename onto it merges. Returns `{deleted note, row id}`.
  defp emptied_folder!(u, v, path) do
    n = note!(u, v, path <> "/m.md")
    row = FolderRows.ref("notes", n.id)
    Repo.query!("UPDATE notes SET deleted_at = now() WHERE id = $1", [dump(n.id)])
    {n, row}
  end

  # A live note outside the folder whose reference names `row`.
  defp straggler!(u, v, row) do
    n = note!(u, v, "Elsewhere/s.md")
    Repo.query!("UPDATE notes SET folder_ref_id = $2 WHERE id = $1", [dump(n.id), dump(row)])
    assert FolderRows.ref("notes", n.id) == row
    n
  end

  defp stamp(att_id) do
    %{rows: [[stamp, nonce]]} =
      Repo.query!("SELECT folder_ref_stamp, path_nonce FROM attachments WHERE id = $1", [
        dump(att_id)
      ])

    {stamp, nonce}
  end

  defp drift_users, do: Drain.candidates(:folder)

  # This transaction's own counters for `table`: `{seq_scan, idx_tup_fetch,
  # n_tup_upd}` (`pg_stat_xact_user_tables` reads the current transaction).
  defp xact(table) do
    %{rows: [[seq, fetch, upd]]} =
      Repo.query!(
        "SELECT seq_scan, coalesce(idx_tup_fetch, 0), n_tup_upd FROM pg_stat_xact_user_tables " <>
          "WHERE relname = $1",
        [table]
      )

    {seq, fetch, upd}
  end

  defp delta({a1, b1, c1}, {a0, b0, c0}), do: {a1 - a0, b1 - b0, c1 - c0}

  # `n` LIVE copies of attachment `att`, spread over `folders` (row ids), each
  # with a fresh path hash so the live unique index holds: a vault with many
  # live attachments in many folders, as in prod, so a lookup by folder is not
  # a tie with walking every live attachment.
  defp clone_live_attachments!(att, n, folders) do
    Repo.query!(
      """
      INSERT INTO attachments
      SELECT (jsonb_populate_record(r, jsonb_build_object('id', uuidv7(),
               'folder_ref_id', ($3::uuid[])[1 + g % cardinality($3::uuid[])],
               'path_hmac', '\\x' || encode(sha256(convert_to(g::text, 'UTF8')), 'hex')))).*
      FROM attachments r, generate_series(1, $2) g
      WHERE r.id = $1
      """,
      [dump(att.id), n, Enum.map(folders, &dump/1)]
    )
  end

  defp folder_rows!(u, v, n),
    do: for(_ <- 1..n, do: FolderRows.insert!(u, v, :crypto.strong_rand_bytes(32)))

  # `n` deleted copies of row `id` of `table` ("notes" or "attachments"):
  # history that keeps its reference, without `n` writes through the app.
  # Deleted rows are outside the live-path unique indexes.
  # `set` overrides columns (a bytea as its `\\x` text, as `to_jsonb` writes it).
  defp clone_deleted!(table, id, n, set \\ %{}) when table in ["notes", "attachments"] do
    set =
      Map.new(set, fn {k, val} ->
        {k,
         if(is_binary(val) and byte_size(val) == 32,
           do: "\\x" <> Base.encode16(val, case: :lower),
           else: val
         )}
      end)

    Repo.query!(
      """
      INSERT INTO #{table}
      SELECT (jsonb_populate_record(r, jsonb_build_object('id', uuidv7(), 'deleted_at', now()) || $3::jsonb)).*
      FROM #{table} r, generate_series(1, $2)
      WHERE r.id = $1
      """,
      [dump(id), n, set]
    )
  end

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

      kill_row!(u, row)

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

      kill_row!(u, row)

      assert FolderRows.ref("attachments", att.id) == nil
      assert {nil, _} = stamp(att.id)
      assert u.id in drift_users()
    end

    test "the drain heals the released reference back to a live row", %{user: u, vault: v} do
      :ok = Engram.DataMigrations.mark_done(FolderTable.name(), FolderTable.version())
      lost = note!(u, v, "Gone/lost.md")
      att = attachment!(u, v, "Gone/a.png")
      kill_row!(u, FolderRows.ref("notes", lost.id))

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

      kill_row!(u, row)

      assert FolderRows.ref("notes", trashed.id) == row
    end

    test "another folder's references and a second delete are left alone", %{
      user: u,
      vault: v
    } do
      kept = note!(u, v, "Kept/n.md")
      gone = note!(u, v, "Gone/n.md")
      kept_row = FolderRows.ref("notes", kept.id)
      gone_row = FolderRows.ref("notes", gone.id)

      # An update that is not a live-to-deleted flip fires nothing.
      Repo.query!("UPDATE folders SET updated_at = now() WHERE id = $1", [dump(kept_row)])
      kill_row!(u, gone_row)
      assert FolderRows.ref("notes", kept.id) == kept_row

      # Re-deleting an already deleted row (a second delete) is not a flip either.
      # The reference to the dead row is replayed with triggers off: written
      # now, `folder_ref_live_only` (20261107090000) would turn it into NULL.
      Repo.query!("SET LOCAL session_replication_role = replica")

      Repo.query!("UPDATE notes SET folder_ref_id = $2 WHERE id = $1", [
        dump(gone.id),
        dump(gone_row)
      ])

      Repo.query!("SET LOCAL session_replication_role = origin")

      Repo.query!("UPDATE folders SET deleted_at = now() WHERE id = $1", [dump(gone_row)])
      assert FolderRows.ref("notes", gone.id) == gone_row
    end

    # M1: a merge rename used to retire the source row BEFORE its moves, so
    # the trigger NULLed every moved row and the move wrote it again: 40 note
    # row versions for 20 notes (46f61399b), then 20 attachment row versions
    # for 10 attachments once the retire sat between the notes and the
    # attachments leg (219907090). The source rows are now retired after both
    # legs: one write per moved row. Red at both.
    test "a merge rename of 20 notes and 10 attachments writes each row once", %{
      user: u,
      vault: v
    } do
      moved = for i <- 1..20, do: note!(u, v, "Src/n#{i}.md")
      atts = for i <- 1..10, do: attachment!(u, v, "Src/a#{i}.png")
      src = FolderRows.ref("notes", hd(moved).id)
      {_gone, keeper} = emptied_folder!(u, v, "Dst")

      before = {xact("notes"), xact("attachments")}
      assert {:ok, _} = rest_call!(fn -> Engram.Folders.rename(u, v, "Src", "Dst") end)
      {_, _, note_updates} = delta(xact("notes"), elem(before, 0))
      {_, _, att_updates} = delta(xact("attachments"), elem(before, 1))

      assert note_updates == 20
      assert att_updates == 10
      assert FolderRows.row(src).deleted_at
      for n <- moved, do: assert(FolderRows.ref("notes", n.id) == keeper)
      for a <- atts, do: assert(FolderRows.ref("attachments", a.id) == keeper)
      refute u.id in drift_users()
    end

    # The #2468 delta review's probe. A straggler: a live note that names the
    # source folder row but that the cascade does not move (its stored path is
    # elsewhere; written in the gap, in the review's H1 race). The merge
    # retires the row, and the straggler must lose the reference, under the
    # app role, through the REST entry points (an outer transaction with NO
    # tenant). Red on d5dbcd173, whose deferred trigger ran at that outer
    # commit with no tenant and so, under FORCE RLS, updated nothing.
    test "a REST merge rename leaves no reference to the retired row", %{user: u, vault: v} do
      note!(u, v, "Src/n.md")
      src = FolderRows.tree(u)["Src"].id
      straggler = straggler!(u, v, src)
      emptied_folder!(u, v, "Dst")

      assert {:ok, _} = rest_call!(fn -> Engram.Folders.rename(u, v, "Src", "Dst") end)

      assert FolderRows.row(src).deleted_at
      assert FolderRows.ref("notes", straggler.id) == nil
      assert u.id in drift_users()
    end

    test "a REST batch move into an existing folder leaves no reference to the retired row", %{
      user: u,
      vault: v
    } do
      {:ok, marker} = Notes.create_folder_marker(u, v, "Src")
      note!(u, v, "Src/n.md")
      src = FolderRows.tree(u)["Src"].id
      straggler = straggler!(u, v, src)
      emptied_folder!(u, v, "T/Src")
      {:ok, target} = Notes.create_folder_marker(u, v, "T")

      assert {:ok, _} =
               rest_call!(fn -> Engram.Folders.batch_move(u, v, [marker.id], target.id) end)

      assert FolderRows.row(src).deleted_at
      assert FolderRows.ref("notes", straggler.id) == nil
      assert u.id in drift_users()
    end

    # CONTROL: the role these tests drop to really is RLS-bound. With no
    # tenant set it sees none of the rows the superuser sees, so a green test
    # above cannot be the role drop silently not engaging.
    test "control: engram_app with no tenant sees zero notes and folders", %{user: u, vault: v} do
      note!(u, v, "Ctl/n.md")
      assert Repo.one(from(n in "notes", select: count()), skip_tenant_check: true) > 0

      assert {0, 0} =
               as_prod_role_committing(fn ->
                 {Repo.one(from(n in "notes", select: count()), skip_tenant_check: true),
                  Repo.one(from(f in "folders", select: count()), skip_tenant_check: true)}
               end)

      assert %{rows: [["engram_app"]]} =
               as_prod_role_committing(fn -> Repo.query!("SELECT current_user") end)
    end

    # M2: the folder's trashed notes keep their reference, so a lookup on the
    # non-partial `notes_folder_ref` fetched every one of them (3,005 rows
    # removed by filter, measured). On `notes_folder_ref_live` the delete
    # path's release reads no note row at all. Red before.
    test "with trashed history in the folder the release reads no row", %{
      user: u,
      vault: v
    } do
      # Born deleted (a live row updated to deleted would leave its old
      # version in the live index until a VACUUM the sandbox cannot run).
      # The folder row holds only history: 2,000 trashed notes and 200
      # deleted attachments, which keep their reference.
      h = :crypto.strong_rand_bytes(32)
      row = FolderRows.insert!(u, v, :crypto.strong_rand_bytes(32), full_path_hmac: h)
      others = for i <- 1..60, do: note!(u, v, "Other#{rem(i, 3)}/n#{i}.md")
      atts = for i <- 1..20, do: attachment!(u, v, "Other#{rem(i, 3)}/a#{i}.png")
      clone_deleted!("notes", hd(others).id, 2_000, %{"folder_hmac" => h})
      clone_deleted!("attachments", hd(atts).id, 200, %{"folder_ref_id" => row})
      clone_live_attachments!(hd(atts), 2_000, folder_rows!(u, v, 100))
      assert FolderRows.ref("notes", hd(others).id) != row

      # Statistics and physical layout from this test's rows only (earlier
      # tests' rolled-back rows leave dead index pages behind).
      QueryPlan.fresh!("notes")
      QueryPlan.fresh!("attachments")
      before = {xact("notes"), xact("attachments")}
      kill_row!(u, row)

      assert delta(xact("notes"), elem(before, 0)) == {0, 0, 0}
      assert delta(xact("attachments"), elem(before, 1)) == {0, 0, 0}
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

    # L3: a marker the delete's marker leg could not see (an undecryptable
    # path, a fence skip) keeps the folder; that is logged, by count only.
    test "rows kept for a live marker are logged with a count and no path or id", %{
      user: u,
      vault: v
    } do
      {:ok, m} = Notes.create_folder_marker(u, v, "F/Sub")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Repo.with_tenant!(u.id, fn -> Rows.soft_delete(u, v.id, ["F"], nil) end)
        end)

      assert log =~ "folder delete: rows kept for live folder markers"
      assert log =~ "kept_count=1"
      refute log =~ "Sub"
      refute log =~ m.id
    end

    test "a delete that removed its markers logs nothing", %{user: u, vault: v} do
      {:ok, _} = Notes.create_folder_marker(u, v, "F/Sub")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _} = Engram.Folders.delete(u, v, "F", recursive: true)
        end)

      refute log =~ "rows kept for live folder markers"
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
      kill_row!(u, t["F/Sub"].id)
      kill_row!(u, t["F"].id)
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
    # With seq scans allowed and realistic history (the folder's trashed
    # notes and attachments keep their reference), the planner must pick the
    # live partial indexes, not the full reference indexes or a table scan.
    test "the trigger's updates use the live reference indexes", %{user: u, vault: v} do
      notes = for i <- 1..150, do: note!(u, v, "Hist/n#{i}.md")
      atts_live = for i <- 1..5, do: attachment!(u, v, "Elsewhere/a#{i}.png")
      att = attachment!(u, v, "Hist/a.png")
      clone_deleted!("attachments", att.id, 1_000)
      clone_live_attachments!(hd(atts_live), 2_000, folder_rows!(u, v, 100))

      Repo.query!("UPDATE notes SET deleted_at = now() WHERE id = ANY($1::uuid[])", [
        Enum.map(notes, &dump(&1.id))
      ])

      Repo.query!("UPDATE attachments SET deleted_at = now() WHERE id = $1", [dump(att.id)])

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
        plan = QueryPlan.generic_plan(sql, analyze: [table], fresh: true, seqscan: true)
        assert plan =~ "#{table}_folder_ref_live", plan
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

        # Exact name (" on" ends it): not `notes_folder_ref_live_id` (S1).
        assert plan =~ "Index Only Scan using notes_folder_ref_live on", plan
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
