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

  Metrics:

    * `engram_prom_ex_crdt_room_drain_total` — tags `[:phase]`.

  ## Reading it

  `released` should track `requested` closely. `requested` climbing while
  `released` stays flat means rooms are being asked to drain and not going
  away — the unbounded-residency failure the drain exists to prevent — and a
  rising `reasked` rate localises it to observers that cannot act (netsplit,
  wedged channels). A rising `skipped` rate means rooms are dying or wedging
  on their own, which is a different bug.

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
