defmodule Engram.PromEx.Crdt do
  @moduledoc """
  PromEx plugin for CRDT room-lifetime signals (#1152).

  Subscribes to:

    * `[:engram, :crdt, :room_drain]` — `%{count: 1}`, metadata `%{phase: atom}`:

      * `:requested` — an idle room asked its observers to let go (first ask).
      * `:reasked` — a follow-up ask, because the previous one changed nothing.
        Emitted at a backed-off interval (`CrdtCheckpointTimer.drain_delay/1`).
      * `:released` — an observer actually unobserved, which is what lets the
        room's `auto_exit` fire and checkpoint.
      * `:skipped` — an observer declined to unobserve because the room was
        already dead or did not answer the liveness probe.
      * `:lru_evicted` — `Engram.Notes.CrdtRoomLru` forced a drain because this
        node was over `max_resident`, i.e. the room was NOT idle and got
        evicted under memory pressure.

  Metrics:

    * `engram_prom_ex_crdt_room_drain_total` — tags `[:phase]`.

  ## Reading it

  `released` should track `requested + lru_evicted` closely. Requests climbing
  while `released` stays flat means rooms are being asked to drain and not going
  away — the unbounded-residency failure the drain exists to prevent — and a
  rising `reasked` rate localises it to observers that cannot act (netsplit,
  wedged channels). A rising `skipped` rate means rooms are dying or wedging
  on their own, which is a different bug.

  `lru_evicted` should normally be **zero**. Sustained non-zero means idle-exit
  alone is not keeping up and the node is running at its resident cap — a
  capacity signal, and the cue to re-tune `max_resident` (or `idle_exit_ms`)
  against real index-doc sizes.

  This is also the only way to answer #1152's "resident room count bounded
  under a soak" in production rather than in a test.

  Cardinality contract: the four phase atoms above and nothing else. NEVER add
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
            "CRDT idle room-drain events by phase (requested | reasked | released | skipped).",
          tags: [:phase]
        )
      ]
    )
  end
end
