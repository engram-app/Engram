defmodule Engram.Workers.IdempotencyPrune do
  @moduledoc """
  Daily sweep of expired idempotency_keys rows (#862). Expired rows already
  read as :miss; this reclaims the storage (each row caches a full encrypted
  batch response body).
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  @impl Oban.Worker
  def perform(_job) do
    {:ok, keys} = Engram.Idempotency.prune_expired()
    {:ok, webhooks} = Engram.Webhooks.Idempotency.prune()

    if keys + webhooks > 0 do
      require Logger
      Logger.info("idempotency_prune keys=#{keys} webhook_events=#{webhooks}")
    end

    :ok
  end
end
