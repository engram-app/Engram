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

  Backed by `Engram.Idempotency` (process-wide ETS, 24h TTL) — long enough to
  cover provider retry windows. A blank/missing id can't be deduped, so it
  always proceeds (signature + timestamp remain the floor).
  """

  alias Engram.Idempotency

  @type source :: :paddle | :clerk

  @doc "Returns `:proceed` if this event hasn't been processed, else `:duplicate`."
  @spec check(source(), String.t() | nil) :: :proceed | :duplicate
  def check(source, id) when is_binary(id) and id != "" do
    case Idempotency.lookup(key(source, id)) do
      {:ok, _} -> :duplicate
      :miss -> :proceed
    end
  end

  def check(_source, _id), do: :proceed

  @doc """
  Records an event id as processed. Call only AFTER successful handling so a
  transient failure leaves the event eligible for the provider's retry.
  """
  @spec mark_processed(source(), String.t() | nil) :: :ok
  def mark_processed(source, id) when is_binary(id) and id != "" do
    Idempotency.remember(key(source, id), :processed)
    :ok
  end

  def mark_processed(_source, _id), do: :ok

  defp key(source, id), do: "webhook:#{source}:#{id}"
end
