defmodule Engram.Workers.ClientLogsPruner do
  @moduledoc """
  Daily retention sweep for `client_logs` (the plugin remote-log sink).

  Deletes rows older than `:client_logs_retention_days` (default 30) in bounded
  batches, so the DELETE never holds a long lock on this write-hot table.

  Added after the 2026-06-29 DB audit found client_logs unbounded at ~98% of
  the database (~737K rows / 147 MB) with no retention (Engram#792).
  client_logs has no RLS, so this cross-user system sweep runs without a tenant
  context.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query
  alias Engram.Repo

  @batch 5_000

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    days = Application.get_env(:engram, :client_logs_retention_days, 30)
    # NaiveDateTime to match the physical `timestamp without time zone` column.
    cutoff = NaiveDateTime.utc_now() |> NaiveDateTime.add(-days * 24 * 3600, :second)
    {:ok, prune(cutoff, 0)}
  end

  defp prune(cutoff, acc) do
    {n, _} =
      Repo.delete_all(
        from(l in "client_logs",
          where:
            l.id in subquery(
              from(s in "client_logs",
                where: s.created_at < ^cutoff,
                select: s.id,
                limit: @batch
              )
            )
        )
      )

    if n >= @batch, do: prune(cutoff, acc + n), else: acc + n
  end
end
