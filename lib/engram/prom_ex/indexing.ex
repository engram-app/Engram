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
    * `engram_prom_ex_indexing_link_rewrite_failures_total` — counter of
      per-source-note link-rewrite failures from `RewriteNoteLinks`
      (rename propagation, #648/#1231), tagged by `:reason`.
    * `engram_prom_ex_indexing_stale_points_leaked_total` — Qdrant points a
      re-index failed to delete after its chunk rows stopped naming them
      (#1592). Each one is deleted content that stays searchable until
      `OrphanSweep`'s weekly point pass reaps it, so a sustained non-zero rate
      is a correctness signal, not a performance one. Expected flat zero.

  Cardinality contract: only `:outcome`/`:reason` (closed enums). NEVER add
  note_id, user_id, or vault_id.
  """

  use PromEx.Plugin

  @repath_stop_event [:engram, :indexing, :repath, :stop]
  @link_rewrite_failed_event [:engram, :links, :rewrite, :failed]
  @stale_points_leaked_event [:engram, :indexing, :stale_points_leaked]

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
        ),
        counter(
          metric_prefix ++ [:link_rewrite, :failures, :total],
          event_name: @link_rewrite_failed_event,
          description:
            "Per-source-note link-rewrite failures (rename propagation, #648/#1231). " <>
              ":reason is a closed set — known pipeline error atoms plus " <>
              ":exception/:other buckets (RewriteNoteLinks.telemetry_failure_reason/1).",
          tags: [:reason]
        ),
        sum(
          metric_prefix ++ [:stale_points_leaked, :total],
          event_name: @stale_points_leaked_event,
          measurement: :count,
          description:
            "Qdrant points a re-index could not delete once its chunk rows stopped " <>
              "naming them (#1592) — deleted content still searchable until OrphanSweep " <>
              "reaps it. Untagged by design; per-note detail is in the log line."
        )
      ]
    )
  end
end
