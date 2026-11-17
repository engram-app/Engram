defmodule Engram.Folders.WriteStopOldPluginTest do
  # S5 without a plugin floor (Engram#2523): a folder rename writes ONE folder
  # row, so no note row gets a new seq. A plugin older than S4 (1.39.3, prod)
  # learns moves only from the seq feed (`crdt_catchup_since`: an upsert with
  # an id at a new path moves the file by id, `moveIfIdRelocated`), from the
  # manifest validator (a note at `seq <= cursor` it has no row for rewinds
  # the cursor), and from `crdt_doc_ready` (an announced path re-maps the id
  # there and moves the file). These pin what such a plugin must see after
  # going offline across a folder rename.
  use EngramWeb.ConnCase, async: true

  alias Engram.{Crypto, Folders, Notes, Repo, ServiceConfig, Sync}
  alias Engram.Folders.{Folder, WriteStop}
  alias Engram.Notes.{CrdtBridge, CrdtCheckpoint, NameIndex}

  @n 7

  setup :authed_api_conn

  setup %{user: user, vault: vault} do
    {:ok, user} = Crypto.ensure_user_dek(user)
    ServiceConfig.put_override(:folder_ops, true)

    for i <- 1..@n, do: put!(user, vault, "A/n#{i}.md", "note #{i}")
    put!(user, vault, "A/sub/deep.md", "deep")
    other = put!(user, vault, "Other/o.md", "other")

    assert WriteStop.on?()
    # The old plugin's cursor: everything before the rename was pulled.
    cursor = Repo.with_tenant!(user.id, fn -> Engram.Vaults.raw_current_seq(vault.id) end)

    %{user: user, vault: vault, cursor: cursor, other: other}
  end

  defp put!(user, vault, path, content) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => content}, actor: "api")

    note
  end

  defp folder_row(user, vault, path) do
    Repo.with_tenant!(user.id, fn ->
      id = Folders.Rows.ids_by_path(user, vault.id, [path])
      Repo.get!(Folder, id[path])
    end)
  end

  # Every row an old plugin's catch-up pages through from `cursor`, with
  # 1.39.3's cursor rule (`walkOpLog`, `cursorAdvances`): the cursor is the
  # max `(seq, id)` of the rows seen, ids compared as strings, never the
  # server's `next`; the walk stops when `has_more` is false or a page did
  # not move the cursor.
  defp walk(user, vault, cursor, limit, opts \\ []) do
    Stream.unfold({cursor, nil}, fn
      :done ->
        nil

      {seq, id} ->
        {max_bytes, opts} = Keyword.pop(opts, :max_bytes)
        page = Sync.merged_changes_page(user, vault, seq, id, limit, :all, max_bytes, opts)
        next = Enum.reduce(page.page, {seq, id}, &max_cursor/2)
        {page.page, if(page.has_more and next != {seq, id}, do: next, else: :done)}
    end)
    |> Enum.to_list()
    |> List.flatten()
  end

  defp max_cursor(%{seq: s, id: i}, {cs, ci}) do
    if s > cs or (s == cs and i > (ci || "")), do: {s, i}, else: {cs, ci}
  end

  # 1.39.3's apply rules, on `files` (path => id): an upsert with an id moves
  # that id's file to the row's path (`moveIfIdRelocated`) or creates it; a
  # delete removes whatever file sits at the row's path (`applyChange`, by
  # path only).
  defp apply_rows(files, rows) do
    Enum.reduce(rows, files, fn
      %{deleted: true, path: path}, files ->
        Map.delete(files, path)

      %{id: id, path: path}, files ->
        files |> Map.reject(fn {_p, i} -> i == id end) |> Map.put(path, id)
    end)
  end

  defp moved_paths do
    Enum.sort(["A/sub/deep.md" | for(i <- 1..@n, do: "A/n#{i}.md")])
  end

  describe "an offline old plugin catching up after a folder rename" do
    test "sees every moved note at its new path, by id, at the folder's seq", ctx do
      %{user: u, vault: v, cursor: cursor} = ctx
      ids = Map.new(moved_paths(), &{String.replace_prefix(&1, "A/", "B/"), note_id(u, v, &1)})

      assert {:ok, _} = Folders.rename(u, v, "A", "B")
      folder = folder_row(u, v, "B")
      refute folder.notes_cascaded

      rows = walk(u, v, cursor, 500)

      assert Enum.map(rows, & &1.path) |> Enum.sort() == Map.keys(ids) |> Enum.sort()
      assert Enum.all?(rows, &(&1.seq == folder.seq and &1.type == :note))
      assert Enum.all?(rows, &(ids[&1.path] == &1.id))
      # No tombstone (nothing to apply by path, nothing to resurrect).
      refute Enum.any?(rows, & &1.deleted)
      # Full rows: the content rides along, as on a cascade's upsert.
      assert Enum.find(rows, &(&1.path == "B/sub/deep.md")).content == "deep"
      # Not older than the move: the plugin drops an id-keyed move whose time
      # is older than the last one it applied for that id.
      assert Enum.all?(rows, &(DateTime.compare(&1.updated_at, folder.updated_at) != :lt))
    end

    test "pages by the keyset without losing or repeating a row", ctx do
      %{user: u, vault: v, cursor: cursor} = ctx
      assert {:ok, _} = Folders.rename(u, v, "A", "B")
      # An unrelated write after the rename, so the merge watermark is used.
      put!(u, v, "Other/later.md", "later")

      rows = walk(u, v, cursor, 2)
      paths = Enum.map(rows, & &1.path)

      assert length(paths) == length(Enum.uniq(paths))

      assert Enum.sort(paths) ==
               Enum.sort([
                 "Other/later.md"
                 | Enum.map(moved_paths(), &String.replace_prefix(&1, "A/", "B/"))
               ])

      keys = Enum.map(rows, &{&1.seq, &1.id})
      assert keys == Enum.sort(keys)
    end

    test "two renames: the last one's paths, nothing at the first", ctx do
      %{user: u, vault: v, cursor: cursor} = ctx
      assert {:ok, _} = Folders.rename(u, v, "A", "B")
      assert {:ok, _} = Folders.rename(u, v, "B", "Other/C")

      paths = walk(u, v, cursor, 3) |> Enum.map(& &1.path) |> Enum.uniq() |> Enum.sort()
      assert paths == Enum.map(moved_paths(), &String.replace_prefix(&1, "A/", "Other/C/"))
    end

    test "a cursor past the rename gets nothing more", ctx do
      %{user: u, vault: v} = ctx
      assert {:ok, %{seq: seq}} = Folders.rename(u, v, "A", "B")
      assert walk(u, v, seq, 500) == []
    end

    test "the S4 plugin pulls no row for the move", ctx do
      %{user: u, vault: v, cursor: cursor} = ctx
      assert {:ok, _} = Folders.rename(u, v, "A", "B")
      assert walk(u, v, cursor, 500, moved: Sync.moved_feed?(WriteStop.s4_plugin())) == []
    end
  end

  describe "quiescence after a move-only change" do
    test "feed_seq_moved reaches the move; feed_seq does not", %{conn: conn} = ctx do
      %{user: u, vault: v} = ctx
      assert {:ok, %{seq: seq}} = Folders.rename(u, v, "A", "B")

      body = conn |> get(~p"/api/sync/quiescence") |> json_response(200)
      assert body["feed_seq_moved"] == seq
      assert body["feed_seq"] < seq
    end

    test "a moved folder with nothing to serve does not count", %{conn: conn} = ctx do
      %{user: u, vault: v} = ctx
      put!(u, v, "E/only.md", "e")
      assert {:ok, _} = Folders.rename(u, v, "E", "E2")
      # Its one note rewritten since: served on its own row, none at the move.
      put!(u, v, "E2/only.md", "edited")
      head = Repo.with_tenant!(u.id, fn -> Engram.Vaults.raw_current_seq(v.id) end)

      body = conn |> get(~p"/api/sync/quiescence") |> json_response(200)
      assert body["feed_seq_moved"] == body["feed_seq"]
      assert body["feed_seq"] == head
    end
  end

  describe "the manifest an old plugin validates against" do
    test "serves a moved note at the move's seq", %{conn: conn} = ctx do
      %{user: u, vault: v, cursor: cursor, other: other} = ctx
      assert {:ok, %{seq: seq}} = Folders.rename(u, v, "A", "B")

      notes = conn |> get(~p"/api/sync/manifest") |> json_response(200) |> Map.fetch!("notes")
      by_path = Map.new(notes, &{&1["path"], &1})

      # Above the old cursor, so the validator leaves it to the replay
      # instead of rewinding the whole feed.
      assert by_path["B/n1.md"]["seq"] == seq
      assert by_path["B/sub/deep.md"]["seq"] == seq
      assert seq > cursor
      # An unmoved note keeps its own seq.
      assert by_path["Other/o.md"]["seq"] == other.seq
    end
  end

  describe "a crdt_doc_ready announce of a moved note" do
    test "carries the path it is shown at, not its stored one", ctx do
      %{user: u, vault: v} = ctx
      note = Notes.get_note(u, v, "A/n1.md") |> elem(1)
      assert {:ok, _} = Folders.rename(u, v, "A", "B")
      EngramWeb.Endpoint.subscribe("crdt:#{u.id}:#{v.id}")

      {:ok, raw} = Repo.with_tenant(u.id, fn -> Engram.Fixtures.raw_note!(note.id) end)
      {:ok, state} = Crypto.decrypt_crdt_state(raw, u)
      {:ok, doc} = CrdtBridge.doc_from_state(state)
      :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), "edited")

      :ok = CrdtCheckpoint.checkpoint(u.id, v.id, note.id, doc)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "crdt_doc_ready",
        payload: %{"doc_id" => id, "path" => "B/n1.md"}
      }

      assert id == note.id
    end

    # The shown-path probe runs outside the window from the write's vault seq
    # lock (`next_seq!`) to its commit, so the lock is held no longer than
    # before (#1710).
    test "resolves the shown path outside the vault lock", ctx do
      %{user: u, vault: v} = ctx
      note = Notes.get_note(u, v, "A/n1.md") |> elem(1)
      assert {:ok, _} = Folders.rename(u, v, "A", "B")

      {:ok, raw} = Repo.with_tenant(u.id, fn -> Engram.Fixtures.raw_note!(note.id) end)
      {:ok, state} = Crypto.decrypt_crdt_state(raw, u)
      {:ok, doc} = CrdtBridge.doc_from_state(state)
      :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), "edited")

      me = self()

      {:ok, queries} =
        Engram.QueryRecorder.record(fn -> CrdtCheckpoint.checkpoint(u.id, v.id, note.id, doc) end)

      sqls = for %{sql: sql, pid: ^me} <- queries, do: sql
      lock = Enum.find_index(sqls, &(&1 =~ "UPDATE vaults SET change_seq"))
      commit = lock && Enum.find_index(Enum.drop(sqls, lock), &(&1 == "commit"))
      probe = Enum.find_index(sqls, &(&1 =~ "NOT m.notes_cascaded"))

      assert lock && commit && probe, inspect(sqls, pretty: true)
      assert probe < lock or probe > lock + commit
    end
  end

  describe "paging the moved-folder feed" do
    test "limit 1 and 2 walk every note once", ctx do
      %{user: u, vault: v, cursor: cursor} = ctx
      assert {:ok, _} = Folders.rename(u, v, "A", "B")

      for limit <- [1, 2] do
        paths = walk(u, v, cursor, limit) |> Enum.map(& &1.path)
        assert length(paths) == @n + 1, "limit #{limit}"
        assert Enum.uniq(paths) == paths, "limit #{limit}"
      end
    end

    test "an emptied moved folder does not stop a later one", ctx do
      %{user: u, vault: v, cursor: cursor} = ctx
      put!(u, v, "E/only.md", "e")
      cursor2 = Repo.with_tenant!(u.id, fn -> Engram.Vaults.raw_current_seq(v.id) end)
      assert {:ok, _} = Folders.rename(u, v, "E", "E2")
      # Its one note written since the move: it rides its own row, and the
      # folder has nothing left to expand.
      put!(u, v, "E2/only.md", "e edited")
      assert {:ok, _} = Folders.rename(u, v, "A", "B")

      rows = walk(u, v, max(cursor, cursor2), 1)
      paths = Enum.map(rows, & &1.path)

      assert "E2/only.md" in paths
      assert Enum.count(paths, &String.starts_with?(&1, "B/")) == @n + 1
      # The edited note once (its own row), not again at the folder's seq.
      assert Enum.count(paths, &(&1 == "E2/only.md")) == 1
    end

    test "a page that ends on a folder's last note moves on to the next folder", ctx do
      %{user: u, vault: v, cursor: cursor} = ctx
      assert {:ok, _} = Folders.rename(u, v, "A", "B")
      assert {:ok, _} = Folders.rename(u, v, "Other", "Other2")

      first = Sync.merged_changes_page(u, v, cursor, nil, @n + 1, :all)
      assert length(first.page) == @n + 1
      assert first.has_more

      {seq, id} = first.next
      second = Sync.merged_changes_page(u, v, seq, id, 500, :all)
      assert Enum.map(second.page, & &1.path) == ["Other2/o.md"]
    end

    test "a wide subtree pages without repeating or losing a note", ctx do
      %{user: u, vault: v, cursor: cursor} = ctx
      for f <- 1..12, i <- 1..3, do: put!(u, v, "W/f#{f}/n#{i}.md", "w")
      cursor = max(cursor, Repo.with_tenant!(u.id, fn -> Engram.Vaults.raw_current_seq(v.id) end))
      assert {:ok, _} = Folders.rename(u, v, "W", "W2")

      paths = walk(u, v, cursor, 5) |> Enum.map(& &1.path)
      assert length(paths) == 36
      assert Enum.uniq(paths) == paths
      assert Enum.all?(paths, &String.starts_with?(&1, "W2/"))
    end
  end

  describe "with the 1.39.3 cursor (max id seen)" do
    test "a folder seq wider than a page, ids interleaved across subfolders and markers",
         ctx do
      %{user: u, vault: v} = ctx
      # Explicit (empty) folders under it: the S5 move rewrites their marker
      # rows at the move's seq.
      assert {:ok, _} = Folders.create_markers(u, v, ["M/e1", "M/x/e2", "M/y/e3"])
      for i <- 1..13, f <- ["x", "y"], do: put!(u, v, "M/#{f}/n#{i}.md", "m")
      cursor = Repo.with_tenant!(u.id, fn -> Engram.Vaults.raw_current_seq(v.id) end)
      assert {:ok, %{seq: seq}} = Folders.rename(u, v, "M", "M2")

      for limit <- [500, 5, 2, 1] do
        rows = walk(u, v, cursor, limit)
        at_move = Enum.filter(rows, &(&1.seq == seq))

        # Every note, once, in id order (the client's cursor is the max id it saw).
        assert length(at_move) == 26, "limit #{limit}"
        assert Enum.map(at_move, & &1.id) == Enum.sort(Enum.map(at_move, & &1.id))
        assert Enum.all?(at_move, &String.starts_with?(&1.path, "M2/"))
      end
    end
  end

  describe "the merge watermark holds the moved feed (X1)" do
    test "a byte budget that cuts the moved feed mid-folder loses no note", ctx do
      %{user: u, vault: v, cursor: cursor} = ctx
      assert {:ok, %{seq: seq}} = Folders.rename(u, v, "A", "B")
      # Notes after the move: rows past its seq that must not overtake it.
      # Tiny, so the merged page fits its byte budget with them in it.
      for i <- 1..4, do: put!(u, v, "Other/after#{i}.md", "x")

      rows = walk(u, v, cursor, 500, max_bytes: 10)
      assert Enum.count(rows, &(&1.seq == seq)) == @n + 1
    end

    test "a second moved folder after the first is not jumped over", ctx do
      %{user: u, vault: v, cursor: cursor} = ctx
      assert {:ok, %{seq: s1}} = Folders.rename(u, v, "A", "B")
      assert {:ok, %{seq: s2}} = Folders.rename(u, v, "Other", "Other2")
      for i <- 1..3, do: put!(u, v, "late#{i}.md", "late")

      rows = walk(u, v, cursor, 500)
      assert Enum.count(rows, &(&1.seq == s1)) == @n + 1
      assert [%{path: "Other2/o.md"}] = Enum.filter(rows, &(&1.seq == s2))
    end

    test "pages below a moved folder read none of its bodies", ctx do
      %{user: u, vault: v} = ctx
      assert {:ok, _} = Folders.rename(u, v, "A", "B")
      me = self()
      handler = "moved-feed-decrypts-#{inspect(me)}"

      :telemetry.attach(
        handler,
        [:engram, :crypto, :decrypt_batch],
        fn _e, %{count: n}, %{kind: :notes}, _ ->
          if self() == me, do: send(me, {:decrypted, n})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      # From 0 with limit 2: the first pages hold notes from before the move,
      # and the notes feed has more below the folder's seq.
      _ = Sync.merged_changes_page(u, v, 0, nil, 2, :all)

      decrypted =
        Stream.repeatedly(fn ->
          receive do
            {:decrypted, n} -> n
          after
            0 -> nil
          end
        end)

      total = decrypted |> Enum.take_while(& &1) |> Enum.sum()

      # The notes feed's own `limit + 1`, nothing for the moved folder.
      assert total <= 3
    end
  end

  describe "a note that died under a moved folder (offline 1.39.3, rejoin replay only)" do
    test "is moved by id, then trashed; nothing at the old path", ctx do
      %{user: u, vault: v, cursor: cursor} = ctx
      held = Map.new(moved_paths(), &{&1, note_id(u, v, &1)})

      assert {:ok, %{seq: seq}} = Folders.rename(u, v, "A", "B")
      :ok = Notes.delete_note(u, v, "B/n1.md")

      rows = walk(u, v, cursor, 3)
      dead_id = held["A/n1.md"]

      # The relocation at the folder's seq, then the tombstone at its own.
      assert [%{seq: ^seq, deleted: false, path: "B/n1.md"}, %{deleted: true, path: "B/n1.md"}] =
               Enum.filter(rows, &(&1.id == dead_id))

      files = apply_rows(held, rows)
      refute Enum.any?(Map.keys(files), &String.starts_with?(&1, "A/"))
      refute Map.has_key?(files, "B/n1.md")
      assert map_size(files) == map_size(held) - 1
    end

    test "a moved folder deleted after the move: every file trashed", ctx do
      %{user: u, vault: v, cursor: cursor} = ctx
      held = Map.new(moved_paths(), &{&1, note_id(u, v, &1)})

      assert {:ok, _} = Folders.rename(u, v, "A", "B")
      assert {:ok, _} = Folders.delete(u, v, "B", recursive: true)

      files = apply_rows(held, walk(u, v, cursor, 4))
      assert files == %{}
    end

    test "two notes that died at one path: nothing live there, no copy", ctx do
      %{user: u, vault: v, cursor: cursor} = ctx
      held = Map.new(moved_paths(), &{&1, note_id(u, v, &1)})
      assert {:ok, _} = Folders.rename(u, v, "A", "B")

      # Two notes die at one path: n1, then a new note created there once
      # the delete-wins window has passed (the tombstone aged here).
      :ok = Notes.delete_note(u, v, "B/n1.md")
      age_tombstones!(v)
      put!(u, v, "B/n1.md", "again")
      :ok = Notes.delete_note(u, v, "B/n1.md")

      rows = walk(u, v, cursor, 2)
      assert Enum.count(rows, &(&1.path == "B/n1.md" and not &1.deleted)) >= 2

      files = apply_rows(held, rows)
      refute Map.has_key?(files, "B/n1.md")
      refute Enum.any?(Map.keys(files), &String.starts_with?(&1, "A/"))
      refute Enum.any?(Map.keys(files), &String.starts_with?(&1, "A/"))
    end

    test "a first sync: one page gets no relocation; a later page may (accepted)", ctx do
      %{user: u, vault: v} = ctx
      assert {:ok, _} = Folders.rename(u, v, "A", "B")
      :ok = Notes.delete_note(u, v, "B/n1.md")

      # A cursor of 0 is a first sync: the dead leg is skipped.
      refute Enum.any?(walk(u, v, 0, 500), &(&1.path == "B/n1.md" and not &1.deleted))

      # Past its first page the server cannot tell a first sync from a
      # client behind the move, so the dead note may be relocated and then
      # trashed (a junk trash entry, m-b, accepted). The end state holds.
      files = apply_rows(%{}, walk(u, v, 0, 2))
      refute Map.has_key?(files, "B/n1.md")
      # Every live note (the setup's @n + 2, less the dead one).
      assert map_size(files) == @n + 1
    end
  end

  describe "a genesis create under a moved folder" do
    test "announces the path it is shown at", ctx do
      %{user: u, vault: v} = ctx
      assert {:ok, _} = Folders.rename(u, v, "A", "B")
      EngramWeb.Endpoint.subscribe("crdt:#{u.id}:#{v.id}")

      id = Ecto.UUID.generate()
      assert {:ok, note} = Notes.genesis_crdt_note(u, v, id, "B/fresh.md")

      assert_receive %Phoenix.Socket.Broadcast{
        event: "crdt_doc_ready",
        payload: %{"doc_id" => ^id, "path" => "B/fresh.md"}
      }

      assert note.id == id
      assert {:ok, %{path: "B/fresh.md"}} = Notes.get_note(u, v, "B/fresh.md")
    end
  end

  describe "MCP name completion" do
    test "offers a moved note at its new path", ctx do
      %{user: u, vault: v} = ctx
      NameIndex.clear()
      assert {:ok, ["A/n1.md" | _], _} = NameIndex.search(u, v, "A/n1", 5)
      assert {:ok, _} = Folders.rename(u, v, "A", "B")
      # The index learns the move (folder_changed marks it stale; the rebuild
      # puts shown paths), with no per-note event.
      Process.sleep(50)
      assert {:ok, paths, _} = NameIndex.search(u, v, "n1", 5)
      assert "B/n1.md" in paths
      refute "A/n1.md" in paths
    end
  end

  defp age_tombstones!(vault) do
    Repo.query!(
      "UPDATE notes SET deleted_at = deleted_at - interval '1 day' " <>
        "WHERE vault_id = $1 AND deleted_at IS NOT NULL",
      [Ecto.UUID.dump!(vault.id)]
    )
  end

  defp note_id(user, vault, path),
    do: Notes.get_note(user, vault, path) |> elem(1) |> Map.get(:id)
end
