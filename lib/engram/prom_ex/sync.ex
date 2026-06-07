defmodule Engram.PromEx.Sync do
  @moduledoc """
  PromEx plugin for the SyncEngine fan-out path (`EngramWeb.SyncChannel`).

  Subscribes to telemetry events emitted by the channel handlers:

    * `[:engram, :sync, :event, :stop]` — `%{duration: native}`, metadata
      `%{op: :push_note | :pull_changes | :delete_note | :rename_note,
         status: :ok | :error}`.

  Metrics:

    * `engram_prom_ex_sync_event_duration_milliseconds` — distribution
      tagged by `:op` + `:status`.
    * `engram_prom_ex_sync_event_total` — counter per op + status; the
      pull-vs-push ratio + error rate are derivable.

  Cardinality contract: bounded `:op` enum + `:status`. NEVER add
  user_id, vault_id, device_id, or path.
  """

  use PromEx.Plugin

  @stop_event [:engram, :sync, :event, :stop]

  @impl true
  def event_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    metric_prefix = PromEx.metric_prefix(otp_app, :sync)

    Event.build(
      :engram_sync_event_metrics,
      [
        distribution(
          metric_prefix ++ [:event, :duration, :milliseconds],
          event_name: @stop_event,
          measurement: :duration,
          description: "SyncChannel handler latency by operation.",
          reporter_options: [
            buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 5_000]
          ],
          tags: [:op, :status],
          unit: {:native, :millisecond}
        ),
        counter(
          metric_prefix ++ [:event, :total],
          event_name: @stop_event,
          description: "SyncChannel events by operation + status.",
          tags: [:op, :status]
        )
      ]
    )
  end
end
