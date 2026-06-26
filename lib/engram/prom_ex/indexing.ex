defmodule Engram.PromEx.Indexing do
  @moduledoc """
  PromEx plugin for index-maintenance telemetry — currently the rename repath
  worker (`Engram.Workers.RepathNoteIndex`, #746/#753).

  Subscribes to:

    * `[:engram, :indexing, :repath, :stop]` — `%{count}`, metadata
      `%{outcome: :ok | :missing_points | :fallback}`:
        - `:ok`             — points PATCHed in place (the cheap, 0-Voyage path);
          `count` is the number of points repathed.
        - `:missing_points` — embedded note had zero points under the old path
          (benign on rapid multi-rename; a real inconsistency otherwise).
        - `:fallback`       — repath exhausted retries and fell back to a full
          re-embed; `count` is 1 (an event tick).

  Metrics:

    * `engram_prom_ex_indexing_repath_total` — counter of repath events by
      `:outcome`. Alert on `:fallback` / `:missing_points` rate; the `:ok` rate
      is the "renames took the cheap path" signal.
    * `engram_prom_ex_indexing_repath_points_total` — sum of `count` by
      `:outcome`. For `:ok` this is total points repathed = the zero-Voyage
      volume saved.

  Cardinality contract: only `:outcome` (closed enum). NEVER add note_id,
  user_id, or vault_id.
  """

  use PromEx.Plugin

  @repath_stop_event [:engram, :indexing, :repath, :stop]

  @impl true
  def event_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    metric_prefix = PromEx.metric_prefix(otp_app, :indexing)

    Event.build(
      :engram_indexing_event_metrics,
      [
        counter(
          metric_prefix ++ [:repath, :total],
          event_name: @repath_stop_event,
          description: "Rename repath outcomes from the RepathNoteIndex worker.",
          tags: [:outcome]
        ),
        sum(
          metric_prefix ++ [:repath, :points, :total],
          event_name: @repath_stop_event,
          measurement: :count,
          description:
            "Qdrant points repathed in place by outcome (0-Voyage volume saved on :ok).",
          tags: [:outcome]
        )
      ]
    )
  end
end
