defmodule Engram.Maintenance.Prune do
  @moduledoc """
  The bounded retention loop every prune shares: delete one batch of at most
  `batch` rows (`delete_batch.(batch)` returns how many it deleted), repeat
  while a batch came back full, at most `max_batches` per run. A backlog drains
  over several runs instead of one WAL and autovacuum burst on a database that
  already swaps. `delete_batch` must bound the rows it READS with an indexed
  predicate (the retention cutoff on an indexed column) and a `LIMIT`.
  """

  # The one per-run cap every prune uses unless a test passes its own.
  @max_batches 20

  @doc "Batches one prune run deletes at most."
  @spec max_batches() :: pos_integer()
  def max_batches, do: @max_batches

  @spec batched((pos_integer() -> non_neg_integer()), pos_integer(), non_neg_integer()) ::
          non_neg_integer()
  def batched(delete_batch, batch, max_batches \\ @max_batches),
    do: loop(delete_batch, batch, max_batches, 0)

  defp loop(_delete_batch, _batch, 0, acc), do: acc

  defp loop(delete_batch, batch, left, acc) do
    case delete_batch.(batch) do
      n when is_integer(n) and n >= batch -> loop(delete_batch, batch, left - 1, acc + n)
      n when is_integer(n) -> acc + n
    end
  end
end
