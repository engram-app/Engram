defmodule Engram.SeqFeedKeysetPlanTest do
  # Guard: a catch-up page seeks to its cursor. The keyset was written as
  # `seq > $s OR (seq = $s AND id > $i)`, which no index can take as a
  # condition: every page walked the vault's feed from seq 0 and threw the
  # rows below the cursor away, so a first sync read O(N^2) rows. A row
  # comparison `(seq, id) > ($s, $i)` is an index range on (vault_id, seq, id).
  use Engram.DataCase, async: true

  alias Engram.QueryPlan
  alias Engram.QueryRecorder

  setup do
    user = insert(:user)
    vault = insert(:vault, user: user)
    for _ <- 1..200, do: insert(:note, user: user, vault: vault)
    for _ <- 1..200, do: insert(:attachment, user: user, vault: vault)
    %{user: user, vault: vault}
  end

  # The cursor is past every row, so the page is empty: factory rows hold no
  # real ciphertext, and only the statement's plan is under test.
  defp feed_sql(fun, table) do
    {_, queries} = QueryRecorder.record(fun)
    for sql <- QueryPlan.reading(queries, table), sql =~ ~s("seq"), do: sql
  end

  defp assert_seeks(sqls, table, index) do
    assert sqls != [], "recorded no #{table} feed read"

    for sql <- sqls do
      plan = QueryPlan.generic_plan(sql, analyze: [table], bitmapscan: false)
      assert plan =~ index, plan
      assert plan =~ ~r/Index Cond: .*ROW\(seq, id\) >/, plan
    end
  end

  test "notes pages seek to (seq, id)", %{user: u, vault: v} do
    sqls =
      feed_sql(
        fn ->
          Engram.Notes.list_changes_by_seq(u, v, 1_000_000_000, after_id: Ecto.UUID.generate())
        end,
        "notes"
      )

    assert_seeks(sqls, "notes", "notes_vault_id_seq_id_index")
  end

  test "attachment pages seek to (seq, id)", %{user: u, vault: v} do
    sqls =
      feed_sql(
        fn ->
          Engram.Attachments.list_changes_by_seq(u, v, 1_000_000_000,
            after_id: Ecto.UUID.generate()
          )
        end,
        "attachments"
      )

    assert_seeks(sqls, "attachments", "attachments_vault_id_seq_id_index")
  end
end
