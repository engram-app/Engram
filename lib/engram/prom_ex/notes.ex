defmodule Engram.PromEx.Notes do
  @moduledoc """
  PromEx plugin for note data-integrity signals.

  Subscribes to:

    * `[:engram, :notes, :utf8_scrub]` — `%{count: 1}`, metadata
      `%{boundary: :write | :read | :search}`. Emitted on the scrub slow path
      (invalid UTF-8 found at a JSON-materializing boundary, see
      `Engram.Notes.Helpers.scrub_utf8/2`). A rising `boundary="write"` rate
      means new corruption is entering at rest — a buggy client — and is
      actionable; `read`/`search` reflect legacy corrupt rows being read and
      drain to zero once the #739 backfill runs.

  Metrics:

    * `engram_prom_ex_notes_utf8_scrub_total` — tags `[:boundary]`.

  Also declared in `EngramWeb.Telemetry.metrics/0`, but that list feeds
  LiveDashboard only — this plugin is what puts it on the scraped `/metrics`
  endpoint that the Grafana Agent sidecar reads.

  Cardinality contract: only the three boundary atoms above. NEVER add
  user_id, vault_id, or note ids.
  """

  use PromEx.Plugin

  @utf8_scrub_event [:engram, :notes, :utf8_scrub]

  @impl true
  def event_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    metric_prefix = PromEx.metric_prefix(otp_app, :notes)

    Event.build(
      :engram_notes_event_metrics,
      [
        counter(
          metric_prefix ++ [:utf8_scrub, :total],
          event_name: @utf8_scrub_event,
          description: "Invalid-UTF-8 scrubs by boundary (write | read | search).",
          tags: [:boundary]
        )
      ]
    )
  end
end
