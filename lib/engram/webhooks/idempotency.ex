defmodule Engram.Webhooks.Idempotency do
  @moduledoc """
  Replay/idempotency guard for inbound webhooks, keyed on the provider's event
  id (Paddle `event_id`, Clerk/svix `svix-id`).

  Signature verification + the timestamp window stop *forged* and *stale*
  requests, but a validly-signed request captured within the window (leaked
  proxy log, retried delivery, misrouted tunnel) can be replayed verbatim and
  passes every check. Webhook handlers are state-convergent, so a replay is not
  catastrophic — but recording processed event ids makes replays explicit
  no-ops instead of re-running side effects (re-issuing PostHog events,
  re-touching subscription state, etc.).

  Backed by the `processed_webhook_events` table (#862) so dedup is
  cross-node and restart-proof — the previous ETS backing was node-local,
  and a provider retry routed to the other node re-ran side effects. Rows
  older than 7 days (well past provider retry windows) are pruned by
  `Engram.Workers.IdempotencyPrune`. A blank/missing id can't be deduped,
  so it always proceeds (signature + timestamp remain the floor).
  """

  import Ecto.Query

  alias Engram.Repo

  @type source :: :paddle | :clerk

  @retention_days 7

  @doc "Returns `:proceed` if this event hasn't been processed, else `:duplicate`."
  @spec check(source(), String.t() | nil) :: :proceed | :duplicate
  def check(source, id) when is_binary(id) and id != "" do
    exists =
      Repo.exists?(
        from(e in "processed_webhook_events",
          where: e.provider == ^to_string(source) and e.event_id == ^id
        )
      )

    if exists, do: :duplicate, else: :proceed
  end

  def check(_source, _id), do: :proceed

  @doc """
  Records an event id as processed. Call only AFTER successful handling so a
  transient failure leaves the event eligible for the provider's retry.
  """
  @spec mark_processed(source(), String.t() | nil) :: :ok
  def mark_processed(source, id) when is_binary(id) and id != "" do
    _ =
      Repo.insert_all(
        "processed_webhook_events",
        [%{provider: to_string(source), event_id: id}],
        on_conflict: :nothing
      )

    :ok
  end

  def mark_processed(_source, _id), do: :ok

  @doc "Deletes rows past the retention window. Called by IdempotencyPrune."
  @spec prune() :: {:ok, non_neg_integer()}
  def prune do
    cutoff = DateTime.add(DateTime.utc_now(), -@retention_days, :day)

    {count, _} =
      Repo.delete_all(from(e in "processed_webhook_events", where: e.inserted_at < ^cutoff))

    {:ok, count}
  end
end
