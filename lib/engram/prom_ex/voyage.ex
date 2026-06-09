defmodule Engram.PromEx.Voyage do
  @moduledoc """
  PromEx plugin for the Voyage AI embedding client (`Engram.Embedders.Voyage`).

  Subscribes to telemetry events emitted by the Voyage adapter:

    * `[:engram, :voyage, :embed, :start]`
    * `[:engram, :voyage, :embed, :stop]` — `%{duration: native}`, metadata
      `%{status: :ok | :error, purpose: :index | :query}`
    * `[:engram, :voyage, :embed, :tokens]` — `%{total_tokens: integer}`,
      metadata `%{purpose: :index | :query}`. Only emitted on a successful
      200 with `usage.total_tokens` present in the Voyage payload.

  Metrics:

    * `engram_prom_ex_voyage_embed_duration_milliseconds` — distribution,
      tags `[:status, :purpose]`. Buckets tuned to observed Voyage latency
      (~100ms-3s).
    * `engram_prom_ex_voyage_embed_total` — counter (one per request); the
      `:status` tag lets `rate({status="error"}) / rate(*)` derive the
      error rate.
    * `engram_prom_ex_voyage_client_rate_limited_total` — counter for the
      synthetic-429 path (`[:engram, :embed, :client_rate_limited]`,
      already emitted by the adapter), tagged by `:purpose`.
    * `engram_prom_ex_voyage_embed_tokens_total` — sum of `total_tokens`
      per request, tagged by `:purpose`. Drives the Grafana tokens/min +
      estimated-cost panels (the dashboard expr multiplies by the
      per-1M-token price as a Grafana constant). NOT per-tenant — see
      `Engram.UsageMeters` for tenant-attributed token accounting.

  Cardinality contract: only bounded labels (`status`, `purpose`). NEVER
  add `user_id`, `vault_id`, model strings, or any per-tenant identifier
  — Voyage RPS × user count would explode the time series.
  """

  use PromEx.Plugin

  @embed_stop_event [:engram, :voyage, :embed, :stop]
  @embed_tokens_event [:engram, :voyage, :embed, :tokens]
  @client_rate_limited_event [:engram, :embed, :client_rate_limited]

  @impl true
  def event_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    metric_prefix = PromEx.metric_prefix(otp_app, :voyage)

    Event.build(
      :engram_voyage_event_metrics,
      [
        distribution(
          metric_prefix ++ [:embed, :duration, :milliseconds],
          event_name: @embed_stop_event,
          measurement: :duration,
          description: "Voyage embedding request latency.",
          reporter_options: [
            buckets: [50, 100, 250, 500, 1_000, 2_000, 3_000, 5_000, 10_000]
          ],
          tags: [:status, :purpose],
          unit: {:native, :millisecond}
        ),
        counter(
          metric_prefix ++ [:embed, :total],
          event_name: @embed_stop_event,
          description: "Voyage embedding requests by status + purpose.",
          tags: [:status, :purpose]
        ),
        counter(
          metric_prefix ++ [:client_rate_limited, :total],
          event_name: @client_rate_limited_event,
          description:
            "Synthetic 429s from the local Hammer throttle — purpose-tagged for tuning :voyage_rpm vs :voyage_query_rpm.",
          tags: [:purpose]
        ),
        sum(
          metric_prefix ++ [:embed, :tokens, :total],
          event_name: @embed_tokens_event,
          measurement: :total_tokens,
          description:
            "Voyage embedding tokens billed, summed per request. Drives tokens/min and estimated-cost dashboard panels. Not per-tenant — see Engram.UsageMeters.",
          tags: [:purpose]
        )
      ]
    )
  end
end
