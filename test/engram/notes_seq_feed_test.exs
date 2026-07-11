defmodule Engram.NotesSeqFeedTest do
  use Engram.DataCase, async: true
  alias Engram.{Notes, Vaults}

  setup do
    user = insert_user()
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "T"})
    %{user: user, vault: vault}
  end

  test "returns rows with seq > cursor in (seq,id) order, includes tombstones", %{
    user: user,
    vault: vault
  } do
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "A"})
    {:ok, _b} = Notes.upsert_note(user, vault, %{"path" => "b.md", "content" => "B"})
    # tombstone, new seq
    :ok = Notes.delete_note(user, vault, "a.md")

    {:ok, %{changes: all}} = Notes.list_changes_by_seq(user, vault, 0)
    # a (deleted) + b both present; the delete carries deleted: true
    assert Enum.any?(all, &(&1.path == "a.md" and &1.deleted))
    assert Enum.any?(all, &(&1.path == "b.md" and not &1.deleted))
    # seq strictly increasing
    seqs = Enum.map(all, & &1.seq)
    assert seqs == Enum.sort(seqs)

    # cursor past last seq returns nothing newer (no later writes)
    last = List.last(all)
    {:ok, %{changes: []}} = Notes.list_changes_by_seq(user, vault, last.seq, after_id: last.id)
  end

  test "single note rename emits an old-path tombstone in the seq feed", %{
    user: user,
    vault: vault
  } do
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "A"})
    {:ok, _} = Notes.rename_note(user, vault, "a.md", "b.md")

    {:ok, %{changes: all}} = Notes.list_changes_by_seq(user, vault, 0)
    assert Enum.any?(all, &(&1.path == "a.md" and &1.deleted))
    assert Enum.any?(all, &(&1.path == "b.md" and not &1.deleted))
  end

  test "rename tombstone does not block re-create at the old path", %{user: user, vault: vault} do
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "A"})
    {:ok, _} = Notes.rename_note(user, vault, "a.md", "b.md")
    assert {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "A2"})
  end

  test "paginates with limit + has_more", %{user: user, vault: vault} do
    for i <- 1..3, do: Notes.upsert_note(user, vault, %{"path" => "n#{i}.md", "content" => "x"})
    {:ok, p1} = Notes.list_changes_by_seq(user, vault, 0, limit: 2)
    assert length(p1.changes) == 2 and p1.has_more
    {c, i} = p1.next
    {:ok, p2} = Notes.list_changes_by_seq(user, vault, c, after_id: i, limit: 2)
    assert length(p2.changes) == 1 and not p2.has_more

    # page boundary: union of both pages covers every row exactly once (no gap, no dup)
    paths = Enum.map(p1.changes ++ p2.changes, & &1.path)
    assert Enum.sort(paths) == ["n1.md", "n2.md", "n3.md"]
  end

  # #976: folder-marker rows (kind="folder") carried path=nil into the cursor
  # feed and crashed tombstone apply on old plugins (new ones skip them, but
  # the feed should not emit them at all). Markers sync via their own
  # endpoint, never the cursor feed.
  test "folder-marker rows are excluded from the seq feed", %{user: user, vault: vault} do
    {:ok, _marker} = Notes.create_folder_marker(user, vault, "Empty")
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "A"})

    {:ok, %{changes: all}} = Notes.list_changes_by_seq(user, vault, 0)
    assert Enum.map(all, & &1.path) == ["a.md"]
  end

  test "folder rename keeps note rows + tombstones in the feed, not the marker", %{
    user: user,
    vault: vault
  } do
    {:ok, _marker} = Notes.create_folder_marker(user, vault, "Old")
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "Old/c.md", "content" => "C"})
    assert {:ok, 2} = Notes.rename_folder(user, vault, "Old", "New")

    {:ok, %{changes: all}} = Notes.list_changes_by_seq(user, vault, 0)
    # renamed note + its old-path tombstone flow through; the marker row does not
    assert Enum.any?(all, &(&1.path == "New/c.md" and not &1.deleted))
    assert Enum.any?(all, &(&1.path == "Old/c.md" and &1.deleted))
    refute Enum.any?(all, &is_nil(&1.path))
  end
end
