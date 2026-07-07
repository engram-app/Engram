defmodule Engram.Notifications.Discord do
  @moduledoc "Fire-and-forget Discord webhook for new issue reports."
  require Logger

  @window_seconds 600
  @desc_limit 1500

  @doc "Post a report to Discord if a webhook URL is configured; otherwise no-op."
  def notify_report(report, user_email) do
    case Application.get_env(:engram, :discord_webhook_url) do
      url when is_binary(url) and url != "" ->
        payload = build_report_payload(report, user_email)
        Task.start(fn -> post(url, payload) end)
        :ok

      _ ->
        :ok
    end
  end

  @doc "Build the Discord message payload for a report. Pure; unit-tested."
  def build_report_payload(report, user_email) do
    from = DateTime.add(report.inserted_at, -@window_seconds, :second)
    to = DateTime.add(report.inserted_at, @window_seconds, :second)
    logql = ~s({service_name="engram-backend"} | user_id="#{report.user_id}")

    content = """
    :beetle: **New issue report** (#{report.surface}, v#{report.app_version})
    user: #{user_email} (`#{report.user_id}`)
    when: #{DateTime.to_iso8601(report.inserted_at)}
    window: #{DateTime.to_iso8601(from)} to #{DateTime.to_iso8601(to)}
    logql: `#{logql}`

    > #{String.slice(report.description, 0, @desc_limit)}#{ellipsis(report.description)}
    """

    %{content: content}
  end

  defp ellipsis(s) when byte_size(s) > @desc_limit, do: "…"
  defp ellipsis(_), do: ""

  defp post(url, payload) do
    case Req.post(url, json: payload, receive_timeout: 10_000, retry: :transient, max_retries: 2) do
      {:ok, %{status: s}} when s in 200..299 -> :ok
      {:ok, %{status: s}} -> Logger.warning("discord webhook non-2xx: #{s}")
      {:error, err} -> Logger.warning("discord webhook failed: #{inspect(err)}")
    end
  end
end
