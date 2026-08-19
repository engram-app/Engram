defmodule Engram.PromEx.Crdt do
  @moduledoc """
  PromEx plugin for CRDT room-lifetime signals (#1152).

  Subscribes to:

    * `[:engram, :crdt, :room_start]` — `%{count: 1}`, no metadata. One event
      per room process actually created (`Engram.Notes.CrdtDoc.start_link/1`),
      so a lookup that resolves to an existing room does not count. The ARRIVAL
      counterpart to `room_drain` below; without it, room allocation over a
      bulk import was unobservable and only instantaneous residency could be
      sampled (#1409).

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

    * `engram_prom_ex_crdt_room_start_total` — untagged.
    * `engram_prom_ex_crdt_room_drain_total` — tags `[:phase]`.
    * `engram_prom_ex_crdt_index_checkpoint_total` — tags `[:phase]`.
    * `engram_prom_ex_crdt_index_projection_total` — tags `[:phase]`.
    * `engram_prom_ex_crdt_index_projection_unresolved_total` — tags `[:phase]`.

  `[:engram, :crdt, :index_projection]` — one event per projection run
  (`Engram.Workers.ProjectVaultIndex`), `%{phase: :converged | :unresolved | …}`.

  **`unresolved` is the signal.** A run that applies nothing because the index
  is empty and a run that fails to apply all forty of its entries are otherwise
  identical to logs, metrics, Oban and Sentry at the same time. Sustained
  non-zero means a vault's index and its rows disagree in a way projection
  cannot fix — a path swap, an entry naming a note that is not there, or one
  note claimed by two paths.

  `[:engram, :crdt, :index_checkpoint]` — `%{count: 1}`, `%{phase: atom}`, from
  `CrdtIndexPersistence.unbind/3`:

    * `:ok` — the vault's index snapshot was written.
    * `:skipped_rotation` — a DEK rotation was in progress, so the checkpoint was
      deliberately skipped. Leaves the index stale, which is recoverable;
      writing under a doomed key would not be.
    * `:failed` — encode, size-cap, encrypt or DB failure. **There is no retry**:
      this runs in `terminate/2` on a `:temporary` room. Any sustained rate means
      vaults are losing index writes permanently, and it is the only signal that
      says so — the failure is otherwise just an absence of log lines.

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

  @claim_event [:engram, :crdt, :index_claim]
  @recheck_event [:engram, :crdt, :index_recheck]
  @in_transaction_event [:engram, :crdt, :index_in_transaction]
  @tail_event [:engram, :crdt, :index_tail]
  @drain_event [:engram, :crdt, :room_drain]
  @start_event [:engram, :crdt, :room_start]
  @checkpoint_event [:engram, :crdt, :index_checkpoint]
  @projection_event [:engram, :crdt, :index_projection]

  @impl true
  def event_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    metric_prefix = PromEx.metric_prefix(otp_app, :crdt)

    Event.build(
      :engram_crdt_event_metrics,
      [
        # Rooms ARRIVING, paired with room_drain below (rooms leaving). Rate of
        # this over a bulk import is the direct measure of the detached genesis
        # seed's headline claim: creating notes must not allocate a room each.
        # Untagged — a room start has no phase, and the alternative (tag by
        # vault or note) is unbounded cardinality.
        counter(
          metric_prefix ++ [:room_start, :total],
          event_name: @start_event,
          description: "CRDT note rooms started (process actually created)."
        ),
        counter(
          metric_prefix ++ [:room_drain, :total],
          event_name: @drain_event,
          description:
            "CRDT idle room-drain events by phase (requested | reasked | request_failed | " <>
              "released | skipped_dead | skipped_unresponsive | lru_evicted).",
          tags: [:phase]
        ),
        counter(
          metric_prefix ++ [:index_checkpoint, :total],
          event_name: @checkpoint_event,
          description:
            "Per-vault CRDT index checkpoint outcomes by phase (ok | skipped_rotation | failed).",
          tags: [:phase]
        ),
        # The WRITE side of the authority the projection metrics below read from.
        # Emitted by `Engram.Notes.Identity` (and by `Engram.Notes` for the
        # `:orphan` route). Without this the module's own argument — that an
        # unobserved subsystem is indistinguishable from an idle one — was
        # unfulfilled: a vault where every rename is refused mid-rotation looked
        # exactly like a vault nobody renamed.
        #
        # Tagged by all three keys on purpose. `phase` alone would merge a room
        # `:conflict` with a snapshot `:conflict`, losing the only dimension
        # that tells them apart. 2 ops x 5 routes x 8 phases bounds the series.
        counter(
          metric_prefix ++ [:index_claim, :total],
          event_name: @claim_event,
          description:
            "Server-side filemeta_v0 writes by op (claim | release), route " <>
              "(gate | room | snapshot | orphan) and phase (ok | conflict | rotation | " <>
              "room_exit | mailbox_empty | load_failed | persist_failed | orphan_claim). " <>
              "route=gate phase=rotation is a write REFUSED before routing because a DEK " <>
              "rotation is running — the caller got an error and did not commit.",
          tags: [:op, :route, :phase]
        ),
        sum(
          metric_prefix ++ [:index_claim, :entries, :total],
          event_name: @claim_event,
          measurement: :entries,
          description: "Index entries touched by server-side claims/releases.",
          tags: [:op, :route, :phase]
        ),
        # Deliberately its own series. Folding it into index_claim made one
        # logical claim register two to four times and report as both :ok and
        # :conflict simultaneously.
        counter(
          metric_prefix ++ [:index_recheck, :total],
          event_name: @recheck_event,
          description: "Re-applications through a room that appeared during a snapshot write.",
          tags: [:op, :phase]
        ),
        # A tripwire, not an outcome. Sustained non-zero means a caller is
        # claiming inside a transaction, where a snapshot write rolls back with
        # the caller but a live-room write does not.
        counter(
          metric_prefix ++ [:index_in_transaction, :total],
          event_name: @in_transaction_event,
          description: "filemeta_v0 writes made inside a caller's transaction (should be 0).",
          tags: [:op]
        ),
        # #1391 — the index tail. `ok` should track index writes closely; a
        # sustained `failed` means claims are living only in room memory, which
        # is exactly the state the tail exists to prevent and is otherwise
        # invisible until a room dies and the claims are simply gone.
        counter(
          metric_prefix ++ [:index_tail, :total],
          event_name: @tail_event,
          description:
            "filemeta_v0 tail-log operations by phase (ok | failed | pruned | " <>
              "corrupt_row | undecryptable_row | skipped_rotation | prune_failed). " <>
              "A sustained `failed` " <>
              "OR `skipped_rotation` both mean the same thing — claims are living only in " <>
              "room memory and die with the process.",
          tags: [:phase]
        ),
        counter(
          metric_prefix ++ [:index_projection, :total],
          event_name: @projection_event,
          description:
            "Per-vault index projection runs by phase (converged | unresolved | no_snapshot | " <>
              "decrypt_failed | corrupt_snapshot | snoozed_rotation | user_gone).",
          tags: [:phase]
        ),
        sum(
          metric_prefix ++ [:index_projection, :unresolved, :total],
          event_name: @projection_event,
          measurement: :unresolved,
          description:
            "Index entries a projection run could not apply (conflict, unknown note, malformed, " <>
              "or a note claimed by two paths).",
          tags: [:phase]
        )
      ]
    )
  end
end
