defmodule Engram.Workers.ClientLogsPruner do
  @moduledoc """
  Hourly retention sweep for `client_logs` (the plugin remote-log sink).

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

  require Logger

  @batch 5_000

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(15)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    days = Application.get_env(:engram, :client_logs_retention_days, 30)
    # NaiveDateTime to match the physical `timestamp without time zone` column.
    cutoff = NaiveDateTime.utc_now() |> NaiveDateTime.add(-days * 24 * 3600, :second)
    n = prune(cutoff, 0)
    if n > 0, do: Logger.info("client_logs_pruner deleted=#{n}")
    {:ok, n}
  end

  # By the time-ordered uuidv7 primary key, not `created_at`: `created_at` has
  # no index (dropped in 20260629230000), so every batch seq-scanned the table.
  # Every id is a server-minted uuidv7 (column default, no app-side mint), and
  # a uuidv7's leading 48 bits are its mint time in ms, so `id < floor(cutoff)`
  # is a pkey range scan. `created_at < cutoff` stays as the correctness bound:
  # no row younger than retention is ever deleted, whatever its id.
  defp prune(cutoff, acc) do
    floor =
      cutoff
      |> DateTime.from_naive!("Etc/UTC")
      |> DateTime.to_unix(:millisecond)
      |> id_floor()

    {n, _} =
      Repo.delete_all(
        from(l in "client_logs",
          where:
            l.id in subquery(
              from(s in "client_logs",
                where: s.id < type(^floor, Ecto.UUID) and s.created_at < ^cutoff,
                order_by: s.id,
                select: s.id,
                limit: @batch
              )
            )
        )
      )

    if n >= @batch, do: prune(cutoff, acc + n), else: acc + n
  end

  # The smallest uuidv7 minted at `ms`: its timestamp bits, then all zeros.
  @doc false
  def id_floor(ms) when is_integer(ms) do
    Ecto.UUID.cast!(<<ms::48, 0::80>>)
  end
end
