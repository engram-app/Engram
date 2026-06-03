defmodule Engram.Observability.PostHog do
  @moduledoc """
  Server-side PostHog event emitter. Thin wrapper around the
  capture endpoint; no Hex dep — Req is already in the tree.

  No-op when `:engram, :posthog_key` is unset (self-host, dev, test).
  Fire-and-forget: the caller never blocks on the POST, and failures
  are logged at `:warning` but don't propagate. Missing analytics
  events must never break the request that emitted them.

  The frontend's `posthog.identify(clerk_user_id, ...)` (see
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
  frontend's `posthog.identify(...)` value — for SaaS users that's
  the Clerk user id; for anonymous flows pass `:anon` and PostHog
  buckets the event under a fallback id.
  """
  @spec capture(String.t() | :anon, String.t(), map()) :: :ok
  def capture(distinct_id, event, properties \\ %{}) when is_binary(event) do
    case config() do
      {key, host} ->
        # Task.start/1 — detached, no supervisor wiring needed.
        # Failure here must not propagate to the caller (a webhook
        # handler, a request pipeline, an Oban worker), so we don't
        # link the spawn.
        Task.start(fn -> do_capture(key, host, distinct_id, event, properties) end)
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
        Logger.warning("posthog capture rejected: status=#{status} body=#{inspect(body)}")

      {:error, reason} ->
        Logger.warning("posthog capture failed: #{inspect(reason)}")
    end
  end

  defp to_distinct_id(:anon), do: "anonymous"
  defp to_distinct_id(id) when is_binary(id), do: id
end
