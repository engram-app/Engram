defmodule Engram.PromEx.Phoenix do
  @moduledoc """
  `PromEx.Plugins.Phoenix` minus the HTTP response-size histogram.

  Delegates everything to the bundled plugin, so request duration, request
  count, channel, socket and endpoint metrics keep their exact names, labels
  (`status method path controller action host`, which Alloy's scrub relabels
  on) and buckets. Only `http_response_size_bytes` is removed: eight buckets
  per route x status x host that no panel read for a decision.
  """
  use PromEx.Plugin

  @impl true
  def event_metrics(opts) do
    opts
    |> PromEx.Plugins.Phoenix.event_metrics()
    |> List.flatten()
    |> Enum.map(fn
      %Event{group_name: :phoenix_http_event_metrics, metrics: metrics} = group ->
        %{
          group
          | metrics: Enum.reject(metrics, &(Enum.take(&1.name, -3) == [:response, :size, :bytes]))
        }

      group ->
        group
    end)
  end
end
