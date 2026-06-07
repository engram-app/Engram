defmodule Engram.PromEx.Search do
  @moduledoc """
  PromEx plugin for the search pipeline (`Engram.Search.search/4`).

  Subscribes to:

    * `[:engram, :search, :request, :stop]` — `%{duration: native,
      result_count: integer}`, metadata `%{status: :ok | :error,
      cross_vault: boolean, rerank: :on | :off}`.
    * `[:engram, :search, :decrypt_failed]` — already registered as a
      Telemetry.Metrics counter in `EngramWeb.Telemetry`; mirroring it
      here so the metric also lands in the PromEx registry without
      double-emitting (telemetry_metrics is fan-out safe — same event
      can drive multiple registries).

  Metrics:

    * `engram_prom_ex_search_request_duration_milliseconds`
    * `engram_prom_ex_search_request_total` — tags `[:status,
      :cross_vault, :rerank]`.
    * `engram_prom_ex_search_results_returned` — distribution on the
      `result_count` measurement so the cardinality of returned results
      is observable.

  Cardinality contract: only the booleans/atoms above. NEVER add
  user_id, vault_id, or the query string.
  """

  use PromEx.Plugin

  @stop_event [:engram, :search, :request, :stop]

  @impl true
  def event_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    metric_prefix = PromEx.metric_prefix(otp_app, :search)

    Event.build(
      :engram_search_event_metrics,
      [
        distribution(
          metric_prefix ++ [:request, :duration, :milliseconds],
          event_name: @stop_event,
          measurement: :duration,
          description: "End-to-end search request latency (embed + Qdrant + rerank).",
          reporter_options: [
            buckets: [10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]
          ],
          tags: [:status, :cross_vault, :rerank],
          unit: {:native, :millisecond}
        ),
        counter(
          metric_prefix ++ [:request, :total],
          event_name: @stop_event,
          description: "Search requests by status, cross-vault, rerank.",
          tags: [:status, :cross_vault, :rerank]
        ),
        distribution(
          metric_prefix ++ [:results, :returned],
          event_name: @stop_event,
          measurement: :result_count,
          description: "Number of search results returned per request.",
          reporter_options: [
            buckets: [0, 1, 5, 10, 25, 50]
          ],
          tags: [:status]
        )
      ]
    )
  end
end
