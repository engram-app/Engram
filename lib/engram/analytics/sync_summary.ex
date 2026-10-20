defmodule Engram.Analytics.SyncSummary do
  @moduledoc """
  The plugin's first-sync summary, sent once when it has planned the initial
  import and once when it finished, as `first_sync_planned` /
  `first_sync_finished`.

  Client-supplied, so every field is checked: counts must be non-negative
  integers (clamped), enums must be known, anything else is dropped. Never a
  path, a title or a vault name. One event per user and phase per hour, so a
  plugin stuck retrying its first sync cannot flood PostHog.
  """

  alias Engram.Analytics

  @max_count 10_000_000
  @window_ms :timer.hours(1)
  @choices ~w(push pull merge)
  @platforms ~w(desktop mobile)

  @doc "Record a summary for `user`. `{:error, :invalid_phase}` for an unknown phase."
  @spec track(map(), map()) :: :ok | {:error, :invalid_phase}
  def track(user, %{"phase" => "planned"} = params) do
    params
    |> counts(~w(notes attachments folders))
    |> put_enum(params, "choice", @choices)
    |> emit(user, "first_sync_planned", params)
  end

  def track(user, %{"phase" => "finished"} = params) do
    props = counts(params, ~w(total failed skipped duration_ms))

    props
    |> Map.put("outcome", outcome(props))
    |> emit(user, "first_sync_finished", params)
  end

  def track(_user, _params), do: {:error, :invalid_phase}

  defp emit(props, user, event, params) do
    props = put_enum(props, params, "platform", @platforms)
    Analytics.track_throttled(user, event, "once", @window_ms, props)
  end

  defp counts(params, keys) do
    for key <- keys, n = params[key], is_integer(n) and n >= 0, into: %{} do
      {key, min(n, @max_count)}
    end
  end

  defp put_enum(props, params, key, allowed) do
    if params[key] in allowed, do: Map.put(props, key, params[key]), else: props
  end

  defp outcome(%{"total" => total, "failed" => failed}) when failed > 0 and failed >= total,
    do: "failed"

  defp outcome(%{"failed" => failed}) when failed > 0, do: "partial"
  defp outcome(_props), do: "complete"
end
