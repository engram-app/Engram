defmodule Engram.Folders.MovedReadsTest do
  # O(1) folder rename plan, S5 readers (Engram#2523). The S5 writer (a later
  # release) renames ONE folder row (`notes_cascaded = false`) and leaves the
  # notes under it at their OLD stored path. This release must already read,
  # write next to, delete and restore such rows correctly, with no writer of
  # its own: it is the writer's rollback target and the code old nodes run in
  # a rolling deploy. The rows here are made in the writer's shape by
  # `FolderRows.move_uncascaded!/3`, never by this release's code.
  use Engram.DataCase, async: true

  alias Engram.{Crypto, FolderRows, Folders, Links, Notes, Repo}
  alias Engram.Folders.Rows
  alias Engram.Links.Parser
  alias Engram.MCP.Handlers

  setup do
    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)

    notes = for i <- 1..3, into: %{}, do: {i, put!(user, vault, "A/n#{i}.md", "note #{i}")}
    _ = put!(user, vault, "A/sub/deep.md", "deep")
    other = put!(user, vault, "Other/o.md", "other")

    # The S5 writer's shape: folder A renamed to B, one row, no note row.
    FolderRows.move_uncascaded!(user, folder_id(user, vault, "A"), "B")

    %{user: user, vault: vault, notes: notes, other: other}
  end

  defp put!(user, vault, path, content) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => content}, actor: "api")

    note
  end

  defp folder_id(user, vault, path),
    do: Repo.with_tenant!(user.id, fn -> Rows.ids_by_path(user, vault.id, [path]) end)[path]

  defp row(user, id) do
    Repo.with_tenant!(user.id, fn ->
      Repo.one(
        from(n in Notes.Note,
          where: n.id == ^id,
          select: %{version: n.version, seq: n.seq, deleted_at: n.deleted_at}
        )
      )
    end)
  end

  defp feed_path(user, vault, id) do
    {:ok, %{changes: changes}} = Notes.list_changes_by_seq(user, vault, 0, limit: 500)
    Enum.find_value(changes, &(&1.id == id && &1.path))
  end

  describe "a save at a moved note's old path" do
    test "REST: a new note, and the moved note is untouched", %{user: u, vault: v, notes: ns} do
      moved = ns[1]
      before = row(u, moved.id)

      fresh = put!(u, v, "A/n1.md", "fresh")

      assert fresh.id != moved.id
      assert row(u, moved.id) == before

      assert {:ok, %{id: id, content: "note 1", path: "B/n1.md"}} =
               Notes.get_note(u, v, "B/n1.md")

      assert id == moved.id
      assert {:ok, %{content: "fresh"}} = Notes.get_note(u, v, "A/n1.md")
    end

    test "MCP write_note: a new note, the moved note keeps its content", %{user: u, vault: v} do
      assert {:ok, _, _} =
               Handlers.handle("write_note", u, v, %{"path" => "A/n2.md", "content" => "mcp"})

      assert {:ok, %{content: "note 2"}} = Notes.get_note(u, v, "B/n2.md")
      assert {:ok, %{content: "mcp"}} = Notes.get_note(u, v, "A/n2.md")
    end

    test "a rename onto it takes it", %{user: u, vault: v, notes: ns} do
      before = row(u, ns[3].id)
      assert {:ok, _} = Notes.rename_note(u, v, "Other/o.md", "A/n3.md")
      assert row(u, ns[3].id) == before
      assert {:ok, %{content: "other"}} = Notes.get_note(u, v, "A/n3.md")
      assert {:ok, %{content: "note 3"}} = Notes.get_note(u, v, "B/n3.md")
    end

    test "a CRDT relocate onto it takes it", %{user: u, vault: v, other: other, notes: ns} do
      before = row(u, ns[3].id)
      assert {:ok, %{id: id}} = Notes.genesis_crdt_note(u, v, other.id, "A/n3.md")
      assert row(u, ns[3].id) == before
      assert id == other.id
      assert {:ok, %{id: ^id}} = Notes.get_note(u, v, "A/n3.md")
      assert {:ok, %{content: "note 3"}} = Notes.get_note(u, v, "B/n3.md")
    end
  end

  describe "reads" do
    test "by path, by id and the CRDT channel's path", %{user: u, vault: v, notes: ns} do
      assert {:error, :not_found} = Notes.get_note(u, v, "A/n1.md")
      assert {:ok, %{path: "B/sub/deep.md"}} = Notes.get_note(u, v, "B/sub/deep.md")
      assert {:ok, %{path: "B/n2.md"}} = Notes.get_note_by_id(u, v, ns[2].id)
      assert Notes.live_note_path(u, v, ns[2].id) == {:ok, "B/n2.md"}
      id2 = ns[2].id
      assert {:ok, %{^id2 => %{path: "B/n2.md"}}} = Notes.get_note_meta_by_ids(u, v, [id2])
    end

    test "a link to the new path resolves to the moved note", %{user: u, vault: v, notes: ns} do
      src = put!(u, v, "idx.md", "[[B/n1]]")
      :ok = Links.replace_links(u, v, src.id, Parser.extract("[[B/n1]]"))
      assert [%{target_note_id: id}] = Links.links_for_note(u, src.id)
      assert id == ns[1].id
    end
  end

  describe "a re-create of a moved note at its new path" do
    test "is not a relocate: no write", %{user: u, vault: v, notes: ns} do
      before = row(u, ns[1].id)
      assert {:ok, %{id: id}} = Notes.genesis_crdt_note(u, v, ns[1].id, "B/n1.md")
      assert id == ns[1].id
      assert row(u, ns[1].id) == before
    end
  end

  describe "deletes leave the tombstone where the note was shown" do
    test "one note", %{user: u, vault: v, notes: ns} do
      assert :deleted = Notes.delete_note_reporting(u, v, "B/n1.md")
      assert feed_path(u, v, ns[1].id) == "B/n1.md"
    end

    test "a batch", %{user: u, vault: v, notes: ns} do
      assert {:ok, %{deleted: 2}} = Notes.batch_delete_notes(u, v, [ns[1].id, ns[2].id])
      assert feed_path(u, v, ns[1].id) == "B/n1.md"
      assert feed_path(u, v, ns[2].id) == "B/n2.md"
    end

    test "the moved folder, recursively", %{user: u, vault: v, notes: ns} do
      assert {:ok, %{notes: 4}} = Folders.delete(u, v, "B", recursive: true)
      assert {:error, :not_found} = Notes.get_note(u, v, "B/n1.md")
      assert {:error, :not_found} = Notes.get_note(u, v, "A/n1.md")
      assert feed_path(u, v, ns[3].id) == "B/n3.md"
      assert {:ok, _} = Notes.get_note(u, v, "Other/o.md")
    end
  end

  test "a cascading rename of the moved folder lands every note", %{user: u, vault: v} do
    assert {:ok, %{notes: 4}} = Folders.rename(u, v, "B", "C")
    assert {:ok, %{path: "C/n1.md"}} = Notes.get_note(u, v, "C/n1.md")
    assert {:ok, %{path: "C/sub/deep.md"}} = Notes.get_note(u, v, "C/sub/deep.md")
    assert {:error, :not_found} = Notes.get_note(u, v, "B/n1.md")
    assert {:error, :not_found} = Notes.get_note(u, v, "A/n1.md")
  end

  # Second review of #2610: every write decision reads ONE shown path.
  describe "writes decide by the shown path" do
    test "a rename of a moved note tombstones its shown path", %{user: u, vault: v, notes: ns} do
      assert {:ok, _} = Notes.rename_note(u, v, "B/n1.md", "Other/z.md")
      {:ok, %{changes: changes}} = Notes.list_changes_by_seq(u, v, 0, limit: 500)

      gone =
        for c <- changes,
            c.id != ns[1].id,
            c[:deleted] == true or not is_nil(c[:deleted_at]),
            do: c.path

      assert "B/n1.md" in gone
      refute "A/n1.md" in gone
    end

    test "a CRDT relocate of a moved note deletes its shown path on the wire",
         %{user: u, vault: v, notes: ns} do
      :ok = EngramWeb.Endpoint.subscribe("sync:#{u.id}:#{v.id}")
      assert {:ok, _} = Notes.genesis_crdt_note(u, v, ns[2].id, "Other/z2.md")

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "note_changed",
                       payload: %{"event_type" => "delete", "path" => "B/n2.md"}
                     },
                     2_000

      refute_received %Phoenix.Socket.Broadcast{
        payload: %{"event_type" => "delete", "path" => "A/n2.md"}
      }
    end

    test "a CRDT create of a moved note at its OLD path moves it there",
         %{user: u, vault: v, notes: ns} do
      assert {:ok, %{id: id}} = Notes.genesis_crdt_note(u, v, ns[3].id, "A/n3.md")
      assert id == ns[3].id
      assert {:ok, %{id: ^id}} = Notes.get_note(u, v, "A/n3.md")
      assert {:error, :not_found} = Notes.get_note(u, v, "B/n3.md")
    end

    test "a free follows a chain of stale keys", %{user: u, vault: v} do
      # X moved to Y, then A moved to X: n1 keys X/k (shown Y/k), n2 keys A/k
      # (shown X/k). A save at A/k frees n2 onto X/k, which n1 still keys.
      n1 = put!(u, v, "X/k.md", "one")
      n2 = put!(u, v, "Q/k.md", "two")
      FolderRows.move_uncascaded!(u, folder_id(u, v, "X"), "Y")
      FolderRows.move_uncascaded!(u, folder_id(u, v, "Q"), "X")
      fresh = put!(u, v, "Q/k.md", "three")
      assert fresh.id not in [n1.id, n2.id]
      assert {:ok, %{content: "one"}} = Notes.get_note(u, v, "Y/k.md")
      assert {:ok, %{content: "two"}} = Notes.get_note(u, v, "X/k.md")
      assert {:ok, %{content: "three"}} = Notes.get_note(u, v, "Q/k.md")
    end

    test "a REST rename takes the vault lock before freeing a holder", %{user: u, vault: v} do
      {_, queries} =
        Engram.QueryRecorder.record(fn ->
          assert {:ok, _} = Notes.rename_note(u, v, "Other/o.md", "A/n1.md")
        end)

      me = self()
      sqls = for %{pid: ^me, sql: sql} <- queries, do: sql

      vault_lock =
        Enum.find_index(
          sqls,
          &(&1 =~ ~r/FROM "?vaults"?.*FOR (NO KEY )?UPDATE|UPDATE "?vaults"?/s)
        )

      free = Enum.find_index(sqls, &(&1 =~ ~r/^UPDATE "notes".*"path_ciphertext"/s))
      assert vault_lock && free && vault_lock < free, inspect(sqls, limit: :infinity)
    end
  end

  describe "target occupancy reads the shown path" do
    setup %{user: u} do
      v = insert(:vault, user: u)
      gone = put!(u, v, "B/x.md", "gone")
      op = Ecto.UUID.generate()
      {:ok, _} = Folders.delete(u, v, "B", recursive: true, op_id: op)
      shown = put!(u, v, "A/x.md", "shown")
      FolderRows.move_uncascaded!(u, folder_id(u, v, "A"), "B")
      %{v2: v, gone: gone, op: op, shown: shown}
    end

    test "a restore onto a path shown by name is refused", %{user: u, v2: v, op: op, shown: s} do
      _ = Folders.restore_op(u, v, op)
      assert {:ok, %{id: id, content: "shown"}} = Notes.get_note(u, v, "B/x.md")
      assert id == s.id
      refute live_at_name?(u, v, s.id)
    end

    test "a resurrect onto a path shown by name is refused", %{user: u, v2: v, shown: s} do
      # Deleted elsewhere, so the same-path delete-wins window is not what refuses it.
      g = put!(u, v, "C/x.md", "elsewhere")
      :deleted = Notes.delete_note_reporting(u, v, "C/x.md")
      assert {:error, :id_conflict, _} = Notes.genesis_crdt_note(u, v, g.id, "B/x.md")
      assert {:ok, %{id: id}} = Notes.get_note(u, v, "B/x.md")
      assert id == s.id
      refute live_at_name?(u, v, s.id)
    end
  end

  # Delta check of #2610: delete-wins answers before the occupancy check, so
  # a stale device still trashes its copy (`recently_deleted`).
  test "a re-create at its own just-deleted path stays recently_deleted when taken",
       %{user: u, vault: v} do
    gone = put!(u, v, "Other/q.md", "gone")
    :deleted = Notes.delete_note_reporting(u, v, "Other/q.md")
    _taker = put!(u, v, "Other/q.md", "taker")
    assert {:error, :recently_deleted} = Notes.genesis_crdt_note(u, v, gone.id, "Other/q.md")
  end

  # Another live note keyed or named where `id` is shown.
  defp live_at_name?(user, vault, id) do
    {:ok, %{changes: changes}} = Notes.list_changes_by_seq(user, vault, 0, limit: 500)
    shown = Enum.find_value(changes, &(&1.id == id && &1.path))

    Enum.any?(
      changes,
      &(&1.id != id and &1[:deleted] != true and is_nil(&1[:deleted_at]) and &1.path == shown)
    )
  end
end
