defmodule Engram.PromEx.Qdrant do
  @moduledoc """
  PromEx plugin for the Qdrant HTTP client (`Engram.Vector.Qdrant`).

  Subscribes to telemetry events emitted by the Qdrant adapter:

    * `[:engram, :qdrant, :request, :start]`
    * `[:engram, :qdrant, :request, :stop]` — `%{duration: native}`,
      metadata `%{op: atom, status: :ok | :error}` where `op` is one of
      `:search | :upsert | :delete | :scroll | :ensure_collection | :set_payload | :collection_info`.

  Metrics:

    * `engram_prom_ex_qdrant_request_duration_milliseconds` — distribution
      tagged by `:op` + `:status`. Buckets tuned to Qdrant local + Cloud
      latency (~5-100ms typical, fall-back up to 5s).
    * `engram_prom_ex_qdrant_request_total` — counter for ops/sec by op +
      status (error-rate derivable).

  Cardinality contract: only `:op` (closed enum) + `:status`. NEVER add
  user_id, vault_id, point ids, or collection names.
  """

  use PromEx.Plugin

  @stop_event [:engram, :qdrant, :request, :stop]

  @impl true
  def event_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    metric_prefix = PromEx.metric_prefix(otp_app, :qdrant)

    Event.build(
      :engram_qdrant_event_metrics,
      [
        distribution(
          metric_prefix ++ [:request, :duration, :milliseconds],
          event_name: @stop_event,
          measurement: :duration,
          description: "Qdrant HTTP request latency by operation.",
          reporter_options: [
            buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 5_000]
          ],
          tags: [:op, :status],
          unit: {:native, :millisecond}
        ),
        counter(
          metric_prefix ++ [:request, :total],
          event_name: @stop_event,
          description: "Qdrant requests by operation + status.",
          tags: [:op, :status]
        )
      ]
    )
  end
end
