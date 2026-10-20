defmodule Engram.Workers.VectorCachePrune do
  @moduledoc """
  Daily retention for `embedding_cache` (`Engram.Indexing.VectorCache.prune/1`):
  rows unused for 30 days, then each user's least recently used rows past the
  per-user bound. Spans tenants, so it runs on `Repo.maintenance/0` and
  refuses (same gate as `ExportExpirySweep`) where only the RLS-filtered app
  pool is available, which would delete nothing and report success.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias Engram.Logger.Metadata
  alias Engram.Repo

  require Logger

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(15)

  @impl Oban.Worker
  def perform(_job) do
    if Repo.maintenance() == Repo and Engram.Repo.TenancyGuard.enforced?() do
      Logger.error(
        "vector_cache_prune refusing to run: RLS is enforced and no maintenance pool is configured",
        Metadata.with_category(:error, :oban, [])
      )

      {:error, :tenancy_unsafe}
    else
      deleted = Engram.Indexing.VectorCache.prune(Repo.maintenance())
      if deleted > 0, do: Logger.info("vector_cache_prune deleted=#{deleted}")
      :ok
    end
  end
end
