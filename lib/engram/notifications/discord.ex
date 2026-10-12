defmodule Engram.Notifications.Discord do
  @moduledoc """
  Fire-and-forget post to a Discord webhook. The caller decides whether a
  webhook is configured; a failed post is logged, never raised, so a ping can
  never break the request that sent it.

  See `docs/context/discord-notification-architecture.md` (workspace) for why
  each of these payload fields is here.
  """

  alias Engram.Logger.Metadata

  require Logger

  # Cloudflare in front of Discord 403s default library user agents.
  @user_agent "EngramBot (https://engram.page, 1)"

  @spec post(String.t(), String.t()) :: :ok
  def post(url, content) when is_binary(url) and is_binary(content) do
    payload = %{
      content: content,
      # User text lands in `content`: never let it ping @everyone or a role.
      allowed_mentions: %{parse: []},
      # SUPPRESS_EMBEDS: a pasted link would otherwise render a preview card.
      flags: 4
    }

    _ = Task.start(fn -> do_post(url, payload) end)
    :ok
  end

  defp do_post(url, payload) do
    case Req.post(url,
           json: payload,
           headers: [{"user-agent", @user_agent}],
           receive_timeout: 10_000,
           retry: :transient,
           max_retries: 2
         ) do
      {:ok, %{status: s}} when s in 200..299 -> :ok
      # The URL carries the webhook token, so it is never logged.
      {:ok, %{status: s}} -> Logger.warning("discord webhook non-2xx: #{s}")
      {:error, err} -> Logger.warning("discord webhook failed: #{Metadata.safe_reason(err)}")
    end
  end
end
