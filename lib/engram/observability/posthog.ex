defmodule Engram.Observability.PostHog do
  @moduledoc """
  Server-side PostHog event emitter. Thin wrapper around the
  capture endpoint; no Hex dep — Req is already in the tree.

  No-op when `:engram, :posthog_key` is unset (self-host, dev, test).
  Fire-and-forget: the caller never blocks on the POST, and failures
  are logged at `:warning` but don't propagate. Missing analytics
  events must never break the request that emitted them.

  The frontend's `posthog.identify(...)` (see
  `auth/clerk-auth-provider.tsx`) binds anonymous device events to
  the user's distinct_id. Server-side events use the same
  distinct_id so funnels join across the timeline. PR8 wires the
  call sites (`note_created`, `search_performed`,
  `vault_opened`, `subscription_started`) and the Clerk/Paddle
  webhook forwarders that depend on this module.
  """

  require Logger

  @capture_path "/capture/"

  @doc """
  Send an event to PostHog. `distinct_id` should match the
  frontend's `posthog.identify(...)` value — the keyed analytics id
  (see `analytics_id/1`); for anonymous flows pass `:anon` and PostHog
  buckets the event under a fallback id.
  """
  @spec capture(String.t() | :anon, String.t(), map()) :: :ok
  def capture(distinct_id, event, properties \\ %{}) when is_binary(event) do
    case config() do
      {key, host} ->
        # Task.start/1 — detached, no supervisor wiring needed.
        # Failure here must not propagate to the caller (a webhook
        # handler, a request pipeline, an Oban worker), so we don't
        # link the spawn. The `{:ok, pid}` is intentionally ignored;
        # explicit underscore so Dialyzer's `unmatched_returns` is
        # satisfied (the value is never useful to a fire-and-forget
        # caller).
        _ = Task.start(fn -> do_capture(key, host, distinct_id, event, properties) end)
        :ok

      :disabled ->
        :ok
    end
  end

  defp config do
    case Application.get_env(:engram, :posthog_key) do
      key when is_binary(key) and byte_size(key) > 0 ->
        host = Application.get_env(:engram, :posthog_host, "https://us.i.posthog.com")
        {key, host}

      _ ->
        :disabled
    end
  end

  defp do_capture(key, host, distinct_id, event, properties) do
    body = %{
      api_key: key,
      event: event,
      distinct_id: to_distinct_id(distinct_id),
      properties: properties,
      timestamp: DateTime.utc_now()
    }

    case Req.post(host <> @capture_path, json: body, receive_timeout: 5_000) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.warning(
          "posthog capture rejected: status=#{status} body=#{inspect(body)}",
          Engram.Logger.Metadata.with_category(:warning, :boot, [])
        )

      {:error, reason} ->
        Logger.warning(
          "posthog capture failed: #{inspect(reason)}",
          Engram.Logger.Metadata.with_category(:warning, :boot, [])
        )
    end
  end

  defp to_distinct_id(:anon), do: "anonymous"
  defp to_distinct_id(id) when is_binary(id), do: id

  @doc """
  Pseudonymous analytics identifier for an email address.

  Keyed, not a bare digest: an email is a low-entropy enumerable input, so an
  unsalted SHA-256 of one is reversible with a wordlist and would not be
  pseudonymisation in any meaningful sense.

  Normalisation and output format are pinned by a test vector. They were once a
  cross-repo contract with `engram-marketing`; that repo's waitlist and its
  email hashing were deleted in #189, so nothing external depends on this
  format today. If a second producer ever appears, it must match this exactly.

  The key is deliberately NON-ROTATING: rotating it re-identifies every person
  in PostHog and orphans all history.
  """
  @spec analytics_id(String.t()) :: String.t()
  def analytics_id(email) when is_binary(email) do
    key = Application.fetch_env!(:engram, :hmac_key_analytics_id)

    :crypto.mac(:hmac, :sha256, key, email |> String.trim() |> String.downcase())
    |> Base.encode16(case: :lower)
  end
end
