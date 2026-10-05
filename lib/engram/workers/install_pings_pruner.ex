defmodule Engram.Workers.InstallPingsPruner do
  @moduledoc """
  Hourly retention sweep for `install_pings` (the self-host census collector).

  The collector is public and keyed by a client-supplied install id, so the
  table has no natural bound. Rows not seen for 35 days are deleted in bounded
  batches. 35 > the 30-day window `Engram.PromEx.Installs` counts, so a row
  never disappears while the gauge could still see it. A live install pings
  daily and refreshes `updated_at`, so it is never pruned.

  `install_pings` has no RLS, so this system sweep runs without a tenant
  context.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query
  alias Engram.Repo

  @retention_days 35
  @batch 5_000

  require Logger

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(15)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    # DateTime to match the physical `timestamptz` column.
    cutoff = DateTime.utc_now() |> DateTime.add(-@retention_days * 24 * 3600, :second)
    n = prune(cutoff, 0)
    if n > 0, do: Logger.info("install_pings_pruner deleted=#{n}")
    {:ok, n}
  end

  defp prune(cutoff, acc) do
    {n, _} =
      Repo.delete_all(
        from(p in "install_pings",
          where:
            p.id in subquery(
              from(s in "install_pings",
                where: s.updated_at < ^cutoff,
                select: s.id,
                limit: @batch
              )
            )
        )
      )

    if n >= @batch, do: prune(cutoff, acc + n), else: acc + n
  end
end
