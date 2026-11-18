defmodule Engram.Notes.LocationLatchTest do
  # A vault holding a folder moved without a cascade (S5) reads names
  # whatever `Location.on?/0` says. Before the latch, names off (the
  # `name_reads` kill switch, or a reopened / version-bumped `note_name`
  # ledger) made every lookup read stored paths: the moved note's stored
  # path is its OLD one, so a write at its shown path minted a second live
  # note on the same folder row with the same name, and once names came back
  # two notes were shown at one path.
  use Engram.DataCase, async: false

  alias Engram.Crypto.NameKeys
  alias Engram.{FolderRows, Folders}
  alias Engram.Folders.WalkSql
  alias Engram.Notes
  alias Engram.Notes.Location
  alias Engram.ServiceConfig

  require WalkSql

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    on_exit(fn -> Engram.Cache.clear_local(:note_name) end)
    %{user: user, vault: vault}
  end

  defp names!(on?) do
    ServiceConfig.put_override(:name_reads, on?)
    assert Location.on?() == on?
  end

  defp live_count(vault) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*)::int FROM notes WHERE vault_id = $1 AND kind = 'note' " <>
          "AND deleted_at IS NULL",
        [Ecto.UUID.dump!(vault.id)]
      )

    n
  end

  test "names off in a moved vault: a write at the shown path updates the moved note",
       %{user: u, vault: v} do
    {:ok, note} = Notes.upsert_note(u, v, %{"path" => "A/x.md", "content" => "old"}, actor: "api")
    FolderRows.move_uncascaded!(u, FolderRows.tree(u)["A"].id, "B")

    names!(false)

    {:ok, written} =
      Notes.upsert_note(u, v, %{"path" => "B/x.md", "content" => "new"}, actor: "api")

    assert written.id == note.id
    assert live_count(v) == 1

    names!(true)
    {:ok, shown} = Notes.list_notes_in_folder(u, v, "B")
    assert [%{id: id, path: "B/x.md"}] = shown
    assert id == note.id
  end

  test "names off in a moved vault: the moved note is still at its shown path",
       %{user: u, vault: v} do
    {:ok, note} = Notes.upsert_note(u, v, %{"path" => "A/x.md", "content" => "x"}, actor: "api")
    FolderRows.move_uncascaded!(u, FolderRows.tree(u)["A"].id, "B")
    names!(false)

    assert {:ok, %{id: id, path: "B/x.md"}} = Notes.get_note(u, v, "B/x.md")
    assert id == note.id
    assert {:error, :not_found} = Notes.get_note(u, v, "A/x.md")
  end

  # Review H1 on #2648: during a `note_name` refill (or after a
  # previous-release rename) a moved row's name stamp is stale, so it is
  # shown at its stored (old) path. The lookup must find it there too, or a
  # write at the shown path mints a second live note.
  test "a moved row with a stale name stamp is found where it is shown", %{user: u, vault: v} do
    {:ok, note} = Notes.upsert_note(u, v, %{"path" => "A/x.md", "content" => "old"}, actor: "api")
    FolderRows.move_uncascaded!(u, FolderRows.tree(u)["A"].id, "B")
    Repo.query!("UPDATE notes SET name_stamp = NULL WHERE id = $1", [Ecto.UUID.dump!(note.id)])

    {:ok, written} =
      Notes.upsert_note(u, v, %{"path" => "A/x.md", "content" => "new"}, actor: "api")

    assert written.id == note.id
    assert live_count(v) == 1
    assert {:ok, %{id: id}} = Notes.get_note(u, v, "A/x.md")
    assert id == note.id
  end

  defp put!(u, v, path, content) do
    {:ok, note} = Notes.upsert_note(u, v, %{"path" => path, "content" => content}, actor: "api")
    note
  end

  defp move!(u, from, to), do: FolderRows.move_uncascaded!(u, FolderRows.tree(u)[from].id, to)

  defp version_seq(u, id) do
    Repo.with_tenant!(u.id, fn ->
      Repo.one(from(n in Notes.Note, where: n.id == ^id, select: {n.version, n.seq}))
    end)
  end

  describe "restore under the latch" do
    # Audit gap: a trashed note restored over a path a moved note is shown at
    # by name. Names off used to skip the name check: a second live note.
    test "onto a path a moved note is shown at: refused, no duplicate", %{user: u, vault: v} do
      op = Ecto.UUID.generate()
      _gone = put!(u, v, "B/x.md", "gone")
      {:ok, _} = Folders.delete(u, v, "B", recursive: true, op_id: op)
      shown = put!(u, v, "A/x.md", "shown")
      move!(u, "A", "B")
      names!(false)

      _ = Folders.restore_op(u, v, op)

      assert {:ok, %{id: id, content: "shown"}} = Notes.get_note(u, v, "B/x.md")
      assert id == shown.id
      assert live_count(v) == 1
    end

    # Its own path is free once the moved note's stale key moves out of the
    # way (`free_slot`): the note comes back where it was, the moved note
    # stays where it is shown.
    test "at its own path, held only by a moved note's stale key", %{user: u, vault: v} do
      op = Ecto.UUID.generate()
      gone = put!(u, v, "A/x.md", "gone")
      :deleted = Notes.delete_note_reporting(u, v, "A/x.md", op_id: op)
      shown = put!(u, v, "A/x.md", "shown")
      assert shown.id != gone.id
      move!(u, "A", "B")
      names!(false)

      _ = Folders.restore_op(u, v, op)

      assert {:ok, %{id: gid, content: "gone"}} = Notes.get_note(u, v, "A/x.md")
      assert gid == gone.id
      assert {:ok, %{id: sid, content: "shown"}} = Notes.get_note(u, v, "B/x.md")
      assert sid == shown.id
      assert live_count(v) == 2
    end
  end

  describe "CRDT create by id (classify_by_id) under the latch" do
    test "at the moved note's shown path: no relocate, no write", %{user: u, vault: v} do
      note = put!(u, v, "A/x.md", "x")
      move!(u, "A", "B")
      names!(false)
      before = version_seq(u, note.id)

      assert {:ok, %{id: id, path: "B/x.md"}} = Notes.genesis_crdt_note(u, v, note.id, "B/x.md")
      assert id == note.id
      assert version_seq(u, note.id) == before
      assert live_count(v) == 1
    end

    test "at its OLD stored path: a relocate, shown there after", %{user: u, vault: v} do
      note = put!(u, v, "A/x.md", "x")
      move!(u, "A", "B")
      names!(false)

      assert {:ok, %{id: id}} = Notes.genesis_crdt_note(u, v, note.id, "A/x.md")
      assert id == note.id

      names!(true)
      assert {:ok, %{id: ^id}} = Notes.get_note(u, v, "A/x.md")
      assert {:error, :not_found} = Notes.get_note(u, v, "B/x.md")
      assert live_count(v) == 1
    end
  end

  # Mixed window: a 0.89.0 node renames the folder with the S5 write stop on
  # (`Folders.rename/5`; this branch's folder writer is 0.89.0's: the PR's
  # diff from release-v0.89.0 touches no writer), then a release D node runs
  # with names off (a `note_name` refill or the kill switch) and serves it.
  test "a 0.89.0 write-stop rename, then names off: D reads and writes the shown path",
       %{user: u, vault: v} do
    ServiceConfig.put_override(:folder_ops, true)
    note = put!(u, v, "A/x.md", "old")
    {:ok, _} = Folders.rename(u, v, "A", "B")

    %{rows: [[false]]} =
      Repo.query!("SELECT notes_cascaded FROM folders WHERE id = $1", [
        Ecto.UUID.dump!(FolderRows.tree(u)["B"].id)
      ])

    names!(false)

    assert {:ok, %{id: id, path: "B/x.md"}} = Notes.get_note(u, v, "B/x.md")
    assert id == note.id
    assert {:error, :not_found} = Notes.get_note(u, v, "A/x.md")
    assert {:ok, [%{id: ^id, path: "B/x.md"}]} = Notes.list_notes_in_folder(u, v, "B")

    assert {:ok, %{id: ^id}} =
             Notes.upsert_note(u, v, %{"path" => "B/x.md", "content" => "new"}, actor: "api")

    assert live_count(v) == 1
  end

  # The name match's holder check reads the stamp version from NameKeys, so a
  # version bump cannot leave the SQL testing the old byte.
  test "the holder check's stamp byte is NameKeys' version" do
    byte = "'\\x" <> Base.encode16(NameKeys.version(), case: :lower) <> "'::bytea"

    for sql <- [WalkSql.name_match_by_id(), WalkSql.name_match_by_hmac()],
        do: assert(sql =~ "p.name_stamp IS DISTINCT FROM (p.path_nonce || " <> byte <> ")")
  end
end
