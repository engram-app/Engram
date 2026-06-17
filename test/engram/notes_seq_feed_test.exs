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
end
