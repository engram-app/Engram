defmodule Engram.NotesHotAppendTest do
  # Every CRDT append (each keystroke flush) clears notes.crdt_head in its
  # CTE (`CrdtPersistence` @append_sql). Postgres updates a row in place (HOT,
  # no new index entries) only if no index's key or predicate references a
  # changed column, so one index on crdt_head turns every keystroke into a new
  # entry in every notes index. Wave 1's notes_crdt_head_missing_index did
  # exactly that and was dropped.
  use Engram.DataCase, async: true

  test "no notes index references crdt_head" do
    %{rows: rows} =
      Repo.query!("""
      SELECT indexrelid::regclass::text, pg_get_indexdef(indexrelid)
      FROM pg_index WHERE indrelid = 'notes'::regclass
      """)

    offending = for [name, defn] <- rows, defn =~ "crdt_head", do: name
    assert offending == []
  end

  test "clearing crdt_head is a HOT update" do
    user = insert(:user)
    note = insert(:note, user: user, vault: insert(:vault, user: user), crdt_head: "h")

    hot = fn ->
      %{rows: [[n]]} =
        Repo.query!("SELECT n_tup_hot_upd FROM pg_stat_xact_user_tables WHERE relname = 'notes'")

      n
    end

    page = fn ->
      %{rows: [[ctid]]} =
        Repo.query!("SELECT ctid::text FROM notes WHERE id = $1", [Ecto.UUID.dump!(note.id)])

      ctid
    end

    before = hot.()
    ctid_before = page.()

    Repo.query!(
      "UPDATE notes SET crdt_head = NULL WHERE id = $1 AND kind = 'note' AND crdt_head IS NOT NULL",
      [Ecto.UUID.dump!(note.id)]
    )

    assert hot.() == before + 1, "ctid #{ctid_before} -> #{page.()}"
  end
end
