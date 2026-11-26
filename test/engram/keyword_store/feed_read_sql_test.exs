defmodule Engram.KeywordStore.FeedReadSqlTest do
  @moduledoc """
  The kwsearch feed reader's query (`native/kwsearch/sql/read.sql`, the
  exact text the Rust reader `include_str!`s) against real Postgres: rows
  come back in NUMERIC xid order and a paged read skips none (review N8).

  The trap it pins: `SELECT xid::text` with no alias names its output column
  `xid`, so `ORDER BY xid` sorts that TEXT column ('1000' < '3847' < '883'),
  and a cursor taken from the last row of a page then skips the rows that
  sort before it as text but after it as numbers.
  """
  use Engram.DataCase, async: true

  @sql_path Path.expand("../../../native/kwsearch/sql/read.sql", __DIR__)
  @external_resource @sql_path

  test "pages of 2 from ('0', 0) return 883, 999, 1000, 3847 in numeric order, none skipped" do
    user = insert(:user)

    for xid <- [3847, 1000, 999, 883] do
      Repo.query!("INSERT INTO keyword_feed (xid, user_id, op) VALUES ($1::text::xid8, $2, 5)", [
        Integer.to_string(xid),
        Ecto.UUID.dump!(to_string(user.id))
      ])
    end

    sql = File.read!(@sql_path)
    page = fn {x, s} -> Repo.query!(sql, [x, s, "4000", 2]) end

    # Columns by position, as the Rust reader reads them: seq, then xid text.
    first = page.({"0", 0})
    [seq, xid | _] = List.last(first.rows)
    second = page.({xid, seq})

    xids = for [_seq, x | _] <- first.rows ++ second.rows, do: String.to_integer(x)
    assert xids == [883, 999, 1000, 3847]
  end
end
