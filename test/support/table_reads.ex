defmodule Engram.TableReads do
  @moduledoc """
  Test helper: rows the current transaction has read from `tables`
  (`seq_tup_read + idx_tup_fetch` in `pg_stat_xact_user_tables`). Under the
  sandbox a test is one transaction, so the delta around a call is what that
  call read, with no other test's reads mixed in.
  """

  alias Engram.Repo

  @spec count([String.t()]) :: non_neg_integer()
  def count(tables) do
    %{rows: [[n]]} =
      Repo.query!(
        """
        SELECT coalesce(sum(coalesce(seq_tup_read, 0) + coalesce(idx_tup_fetch, 0)), 0)::bigint
        FROM pg_stat_xact_user_tables WHERE relname = ANY($1)
        """,
        [tables]
      )

    n
  end
end
