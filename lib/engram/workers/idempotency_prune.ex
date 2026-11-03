defmodule Engram.Workers.IdempotencyPrune do
  @moduledoc """
  Hourly sweep of expired idempotency_keys rows (#862). Expired rows already
  read as :miss; this reclaims the storage (each row caches a full encrypted
  batch response body). Also bounds `processed_webhook_events` (7 days, claims
  730) and `client_origin_stats` (30 days), each in capped, indexed batches.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(15)

  @impl Oban.Worker
  def perform(_job) do
    {:ok, keys} = Engram.Idempotency.prune_expired()
    {:ok, webhooks} = Engram.Webhooks.Idempotency.prune()
    # client_origin_stats retention (30 days; it had none, Job Load Audit
    # 2026-11-03): hourly with the other dedup/counter tables.
    origin_stats = Engram.Abuse.OriginStats.prune()

    if keys + webhooks + origin_stats > 0 do
      require Logger

      Logger.info(
        "idempotency_prune keys=#{keys} webhook_events=#{webhooks} origin_stats=#{origin_stats}"
      )
    end

    :ok
  end
end
