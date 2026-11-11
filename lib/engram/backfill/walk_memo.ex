defmodule Engram.Backfill.WalkMemo do
  @moduledoc """
  The last complete walk of a paced backfill chain and how many rows it
  fixed, kept in `maintenance_cursors` (so every node sees it), and the one
  rule that bounds a ledger that cannot finish: no new full-table walk within
  `retry_after_s/0` (24 h) of a complete walk that fixed nothing. Rows a
  fruitless walk could not handle need something else to change first (a
  writer, a key coming back), so re-walking the table every hour only costs
  the database. Shared by `Engram.DataMigrations.NameTerms` (S1) and
  `Engram.DataMigrations.NoteName` (S2).
  """

  alias Engram.Maintenance.Cursor

  @retry_after_s 86_400

  @doc "The quiet period after a fruitless walk (seconds)."
  @spec retry_after_s() :: 86_400
  def retry_after_s, do: @retry_after_s

  @doc "Records that the walk `key` completed, having fixed `fixed` rows."
  @spec walked(String.t(), non_neg_integer()) :: :ok
  def walked(key, fixed),
    do: Cursor.put(key, %{"fixed" => fixed, "at" => DateTime.to_iso8601(DateTime.utc_now())})

  @doc "True while the last complete walk `key` fixed nothing and is under `retry_after_s/0` old."
  @spec fruitless?(String.t()) :: boolean()
  def fruitless?(key) do
    with %{"fixed" => 0, "at" => at} <- Cursor.get(key),
         {:ok, at, _} <- DateTime.from_iso8601(at) do
      DateTime.diff(DateTime.utc_now(), at) < @retry_after_s
    else
      _ -> false
    end
  end
end
