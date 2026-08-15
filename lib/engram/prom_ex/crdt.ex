defmodule Engram.PromEx.Crdt do
  @moduledoc """
  PromEx plugin for CRDT room-lifetime signals (#1152).

  Subscribes to:

    * `[:engram, :crdt, :room_drain]` — `%{count: 1}`, metadata `%{phase: atom}`:

      * `:requested` — an idle room asked its observers to let go (first ask).
      * `:reasked` — a follow-up ask, because the previous one changed nothing.
        Emitted at a backed-off interval (`CrdtCheckpointTimer.drain_delay/1`).
      * `:request_failed` — the PubSub broadcast itself errored, so NO observer
        was asked. Kept out of `requested` so that count never reports an ask
        that did not go out.
      * `:released` — an observer actually unobserved, which is what lets the
        room's `auto_exit` fire and checkpoint.
      * `:skipped_dead` — the room was already gone, so there was nothing to
        release. Benign.
      * `:skipped_unresponsive` — **not** benign. The room is ALIVE but did not
        answer the liveness probe, so the observer still counts against its
        `auto_exit` and the room stays resident until a later re-ask succeeds.
      * `:lru_evicted` — `Engram.Notes.CrdtRoomLru` forced a drain because this
        node was over `max_resident`, i.e. the room was NOT idle and got
        evicted under memory pressure. Counts asks that were actually
        broadcast; a failed broadcast is logged and NOT counted.

  Metrics:

    * `engram_prom_ex_crdt_room_drain_total` — tags `[:phase]`.

  ## Reading it

  **`requested` and `released` are not directly comparable.** A request is
  emitted ONCE PER ROOM (one broadcast); a release is emitted once per
  OBSERVING CHANNEL. A healthy vault with 3 devices on a note yields roughly
  `3 × released` per `requested`, and the multiplier is unbounded and unknowable
  from this metric — `SharedDoc` keeps `observer_process` private, which is why
  the drain is a broadcast in the first place. Do not alert on their ratio.

  What IS readable:

    * `skipped_unresponsive` — should be ~zero. Any sustained rate means rooms
      are being pinned by observers that cannot let go. This is the
      unbounded-residency failure the drain exists to prevent.
    * `reasked` — should be ~zero. A sustained rate localises the same problem
      to observers that never act (netsplit, wedged channels).
    * `lru_evicted` — should normally be **zero**. Sustained non-zero means
      idle-exit alone is not keeping up and the node is running at its resident
      cap — a capacity signal, and the cue to re-tune `max_resident` (or
      `idle_exit_ms`) against real index-doc sizes.
    * `skipped_dead` — routine. Rooms die on their own all the time.

  Together with the BEAM memory gauges this is how #1152's "resident room count
  bounded under a soak" gets answered in production rather than in a test.

  Cardinality contract: the phase atoms listed above and nothing else. NEVER add
  note_id, vault_id, or user_id — there is one series per phase, and a room
  drains repeatedly.
  """

  use PromEx.Plugin

  @drain_event [:engram, :crdt, :room_drain]

  @impl true
  def event_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    metric_prefix = PromEx.metric_prefix(otp_app, :crdt)

    Event.build(
      :engram_crdt_event_metrics,
      [
        counter(
          metric_prefix ++ [:room_drain, :total],
          event_name: @drain_event,
          description:
            "CRDT idle room-drain events by phase (requested | reasked | request_failed | " <>
              "released | skipped_dead | skipped_unresponsive | lru_evicted).",
          tags: [:phase]
        )
      ]
    )
  end
end
