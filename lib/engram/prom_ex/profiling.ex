defmodule Engram.PromEx.Profiling do
  @moduledoc """
  PromEx plugin exposing the Pyroscope sampler's own cost on `/metrics`,
  so a profiling rollout can be proven cheap before it is trusted.

  Event + metrics:

    * `[:engram, :pyroscope, :sample]` →
      `..._sample_duration_milliseconds` (distribution): wall time of one
      `Process.list/0` sweep. If this approaches the sample interval the
      sampler is throttling and the reported `sampleRate` is inaccurate.
    * `..._sample_process_count` (last value): processes on the node at
      the last pass, the multiplier on sampler cost.

  Cardinality contract: measurements only, no tags. Never user/vault/note ids.
  """

  use PromEx.Plugin

  @impl true
  def event_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    metric_prefix = PromEx.metric_prefix(otp_app, :profiling)

    Event.build(
      :engram_profiling_event_metrics,
      [
        distribution(
          metric_prefix ++ [:sample, :duration, :milliseconds],
          event_name: [:engram, :pyroscope, :sample],
          measurement: :duration_ms,
          description: "Wall time of one Pyroscope sampler pass (Process.list sweep).",
          unit: :millisecond,
          reporter_options: [buckets: [0.5, 1, 2, 5, 10, 20, 50, 100]]
        ),
        last_value(
          metric_prefix ++ [:sample, :process_count],
          event_name: [:engram, :pyroscope, :sample],
          measurement: :process_count,
          description: "Processes on the node at the last Pyroscope sampler pass."
        )
      ]
    )
  end
end
