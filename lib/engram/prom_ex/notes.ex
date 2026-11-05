defmodule Engram.PromEx.Notes do
  @moduledoc """
  PromEx plugin for note data-integrity signals.

  Subscribes to:

    * `[:engram, :notes, :utf8_scrub]` — `%{count: 1}`, metadata
      `%{boundary: :write | :read | :search | :backfill | :broadcast}`. Emitted on the scrub
      slow path (invalid UTF-8 found at a JSON-materializing boundary, see
      `Engram.Notes.Helpers.scrub_utf8/2`). A rising `boundary="write"` rate
      means new corruption is entering at rest — a buggy client — and is the
      ONLY alert-worthy series; `read`/`search` reflect legacy corrupt rows
      being read, and `backfill` is the #739 repair sweep cleaning them. All
      three drain to zero once the backfill completes.

      NB: the counter measures scrub *operations*, not corrupt notes — `:read`
      ticks once per corrupt FIELD (content/title/folder/each tag) per read,
      so its magnitude over-counts notes. For a true corrupt-note count use
      `Engram.Notes.Utf8Backfill.scan/1`.

    * `[:engram, :notes, :read_rebuild]`: `%{count: 1}`, no metadata. A
      user-facing read (`Notes.get_note/3`, `get_note_by_id/3`) found
      un-checkpointed tail rows and rebuilt the note's text from its CRDT
      snapshot and tail (a decrypt plus a Yjs doc rebuild). Its rate against
      the read rate is the share of reads paying that cost.

    * `[:engram, :note_body, :sync_wrote]`: `%{count: rows}`, no metadata.
      `Engram.Notes.NoteBody.sync!/3` wrote body rows, the only writer of
      `note_bodies` since the `notes_sync_body` trigger was dropped
      (20261104000000): the body write rate. On a release that still has the
      trigger it reads zero (the trigger wrote first).

  Metrics:

    * `engram_prom_ex_notes_utf8_scrub_total` — tags `[:boundary]`.
    * `engram_prom_ex_notes_read_rebuild_total`: no tags.
    * `engram_prom_ex_notes_body_sync_wrote_rows_total`: no tags.

  Also declared in `EngramWeb.Telemetry.metrics/0`, but that list feeds
  LiveDashboard only — this plugin is what puts it on the scraped `/metrics`
  endpoint that the Grafana Agent sidecar reads.

  Cardinality contract: only the three boundary atoms above. NEVER add
  user_id, vault_id, or note ids.
  """

  use PromEx.Plugin

  @utf8_scrub_event [:engram, :notes, :utf8_scrub]
  @read_rebuild_event [:engram, :notes, :read_rebuild]
  @body_sync_wrote_event [:engram, :note_body, :sync_wrote]

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
          description:
            "Invalid-UTF-8 scrubs by boundary (write | read | search | backfill | broadcast).",
          tags: [:boundary]
        ),
        counter(
          metric_prefix ++ [:read_rebuild, :total],
          event_name: @read_rebuild_event,
          description: "Note reads that rebuilt the text from the CRDT snapshot and tail."
        ),
        sum(
          metric_prefix ++ [:body_sync_wrote, :rows, :total],
          event_name: @body_sync_wrote_event,
          measurement: :count,
          description:
            "note_bodies rows NoteBody.sync! wrote (every body write since the trigger drop)."
        )
      ]
    )
  end
end
