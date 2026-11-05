defmodule Engram.Workers.ClientLogsPruner do
  @moduledoc """
  Hourly retention sweep for `client_logs` (the plugin remote-log sink).

  Deletes rows older than `:client_logs_retention_days` (config.exs, 7) in bounded
  batches, so the DELETE never holds a long lock on this write-hot table, and
  at most `Engram.Maintenance.Prune.max_batches/0` batches per run, so a backlog drains over several
  hourly runs instead of one burst.

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
  # At most `Prune.max_batches/0` batches (100k rows) per hourly run.
  # Cutting retention (30 -> 7 days) left a ~0.5M-row backlog; deleting it in
  # one back-to-back burst is a WAL/IO spike plus an autovacuum pass on an RDS
  # instance that already swaps. The cron drains the rest over the next hours.

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(15)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    days = Application.fetch_env!(:engram, :client_logs_retention_days)
    # A UTC DateTime, bound uncast below: Postgres types the parameter from
    # `created_at`, so the cutoff is the same instant whether that column is
    # `timestamp` or `timestamptz`, whatever the session TimeZone.
    cutoff = DateTime.add(DateTime.utc_now(), -days * 24 * 3600, :second)
    # Args exist so a test can exercise the cap with a handful of rows.
    batch = Map.get(args, "batch", @batch)
    n = prune(cutoff, batch, Map.get(args, "max_batches", Engram.Maintenance.Prune.max_batches()))
    if n > 0, do: Logger.info("client_logs_pruner deleted=#{n}")
    {:ok, n}
  end

  # By the time-ordered uuidv7 primary key, not `created_at`: `created_at` has
  # no index (dropped in 20260629230000), so every batch seq-scanned the table.
  # Every id is a server-minted uuidv7 (column default, no app-side mint), and
  # a uuidv7's leading 48 bits are its mint time in ms, so `id < floor(cutoff)`
  # is a pkey range scan. `created_at < cutoff` stays as the correctness bound:
  # no row younger than retention is ever deleted, whatever its id.
  defp prune(cutoff, batch, max_batches) do
    floor =
      cutoff
      |> DateTime.to_unix(:millisecond)
      |> id_floor()

    Engram.Maintenance.Prune.batched(
      fn batch ->
        {n, _} =
          Repo.delete_all(
            from(l in "client_logs",
              where:
                l.id in subquery(
                  from(s in "client_logs",
                    where: s.id < type(^floor, Ecto.UUID) and s.created_at < ^cutoff,
                    order_by: s.id,
                    select: s.id,
                    limit: ^batch
                  )
                )
            )
          )

        n
      end,
      batch,
      max_batches
    )
  end

  # The smallest uuidv7 minted at `ms`: its timestamp bits, then all zeros.
  @doc false
  def id_floor(ms) when is_integer(ms) do
    Ecto.UUID.cast!(<<ms::48, 0::80>>)
  end
end
