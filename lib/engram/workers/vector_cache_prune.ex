defmodule Engram.Workers.VectorCachePrune do
  @moduledoc """
  Retention for `embedding_cache` (`Engram.Indexing.VectorCache.prune/1`):
  rows inserted more than 72 h ago, deleted in batches. Spans tenants, so it
  runs on `Repo.maintenance/0`. A no-op when the cache is off, and where only
  the RLS-filtered app pool exists (a self-host without a maintenance pool),
  which would delete nothing; there it logs at info, never an error.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias Engram.Indexing.VectorCache
  alias Engram.Repo

  require Logger

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(15)

  @impl Oban.Worker
  def perform(_job) do
    cond do
      # Off: the table is never written, so there is nothing to expire.
      not VectorCache.enabled?() ->
        :ok

      # A single-pool install that enforces RLS cannot see across tenants;
      # the delete would match zero rows. Skip quietly rather than fail daily.
      Repo.maintenance() == Repo and Engram.Repo.TenancyGuard.enforced?() ->
        Logger.info("vector_cache_prune skipped: no maintenance pool")
        :ok

      true ->
        deleted = VectorCache.prune(Repo.maintenance())
        if deleted > 0, do: Logger.info("vector_cache_prune deleted=#{deleted}")
        :ok
    end
  end
end
