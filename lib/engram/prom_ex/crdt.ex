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

  ## Residency is polled, not evented (#1493)

  Every metric above is a COUNTER. Counters answer "how many arrived" and can
  never answer "how many are here NOW" — the only question a memory backstop is
  tuned against. The 2026-08-28 prod sync peaked at **314 resident rooms against
  a cap of 64** and the sole record of it is a `Logger.warning` line emitted by
  the LRU sweep, so nothing could alert and nothing could be graphed.

  `..._crdt_rooms_resident` / `..._crdt_rooms_cap` close that. Read them as a
  RATIO: the cap ships alongside the count precisely so a dashboard never
  hardcodes 64 and starts lying when the config moves.

  Two limits to know before trusting the number:

    * It counts **rooms, not bytes**. Each room holds its Yjs doc inside the
      `y_ex` NIF, which is off-heap and invisible to `:erlang.memory/0`, so no
      BEAM gauge — `beam_memory_allocated` included — counts the dominant cost
      of a room. This gauge is the closest available proxy, and the reason the
      cap is count-based in the first place. It is also why note rooms and index
      rooms (~50x heavier, per `CrdtRoomLru`'s moduledoc) weigh the same here.
    * It can **overcount**, never undercount. `resident_count/0` reads the raw
      ETS size. An exiting room normally removes its own entry promptly — its
      `CrdtCheckpointTimer` traps the room's `{:EXIT, …}` and calls
      `CrdtRoomLru.forget/1` — so this is close to live. What it misses is the
      case where that timer itself died abnormally, which the sweep's
      `prune_dead` reclaims within one interval (30s). Left as-is deliberately:
      for a memory alarm stale-high is the safe direction, and pruning on a 15s
      scrape would make a metrics read mutate the table the LRU is mid-decision
      on.

  Per-node by construction — memory is per-node and each node bounds its own
  residency — so aggregate with `max by (instance)`, never `sum`.

  Cardinality contract: the phase atoms listed above and nothing else. NEVER add
  note_id, vault_id, or user_id — there is one series per phase, and a room
  drains repeatedly.
  """

  use PromEx.Plugin

  alias Engram.Notes.CrdtRoomLru

  @claim_event [:engram, :crdt, :index_claim]
  @rooms_event [:engram, :crdt, :rooms]
  @recheck_event [:engram, :crdt, :index_recheck]
  @in_transaction_event [:engram, :crdt, :index_in_transaction]
  @tail_event [:engram, :crdt, :index_tail]
  @drain_event [:engram, :crdt, :room_drain]
  @start_event [:engram, :crdt, :room_start]
  @checkpoint_event [:engram, :crdt, :index_checkpoint]
  @abort_event [:engram, :crdt, :checkpoint_abort]
  @projection_event [:engram, :crdt, :index_projection]
  @doc_event [:engram, :crdt, :checkpoint_doc]
  @sweep_event [:engram, :crdt, :state_sweep]

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
        # Tagged by the call path that allocated it, NOT by vault or note (which
        # would be unbounded cardinality). `source` is a small closed set of
        # atoms fixed in code.
        #
        # Count alone says how many rooms an import allocated; it cannot say
        # WHY. The 2026-08-19 staging import measured 406 rooms for 1,516 notes
        # and the remaining 27% could not be attributed to a path, which is the
        # question the routing rework has to answer.
        counter(
          metric_prefix ++ [:room_start, :total],
          event_name: @start_event,
          description: "CRDT note rooms started (process actually created), by call path.",
          tags: [:source]
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
        # #959. A note whose stored crdt_state cannot be decrypted aborts its
        # checkpoint forever: content freezes at the last good checkpoint while
        # every tick appends another tail row.
        #
        # `quarantined` is a DIMENSION, not a separate phase. Escalation must not
        # move an abort off `phase="unreadable_state"`, or an alert written
        # against that phase resolves the moment a note gets bad enough to cross
        # the threshold — silence on the worst notes. Alert on the phase; use the
        # dimension to sort by urgency.
        #
        # No note_id label. This is a per-note condition, but note_id is
        # unbounded cardinality (2026-07-02 audit). The counter tells you to
        # look; the log line carries the note_id and the tail depth.
        #
        # No depth gauge, deliberately. Tagged by phase it would flap between
        # notes every tick, and the depth read is capped at the threshold, so it
        # could never show the unbounded growth such a gauge would imply. Depth
        # belongs on the log line, where it is per-note by construction.
        counter(
          metric_prefix ++ [:checkpoint_abort, :total],
          event_name: @abort_event,
          description:
            "CRDT checkpoint aborts on unreadable stored state, by quarantine status. " <>
              "Sustained non-zero means a note is frozen and its tail log is growing; " <>
              "quarantined=true means it has crossed the depth threshold.",
          tags: [:phase, :quarantined]
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
        # #1706. `crdt_state_ciphertext` is the largest column in the database
        # and it grows monotonically with edit count, but nothing ever measured
        # how far it runs ahead of the text it encodes. Untagged and
        # distribution-only: the whole question is the SHAPE across notes, and
        # note_id / vault_id are unbounded labels (2026-07-02 audit).
        #
        # Emitted pre-flatten, so the gate rework in #1707 reads the bloat it is
        # supposed to catch rather than what a previous flatten already took.
        distribution(
          metric_prefix ++ [:checkpoint_doc, :bloat_ratio],
          event_name: @doc_event,
          measurement: :bloat_ratio,
          description:
            "CRDT doc state bytes divided by projected content bytes, per markdown checkpoint. " <>
              "1.0 means the encoded doc costs what its text costs; high values are accumulated " <>
              "tombstones and stale client IDs. Notes under " <>
              "Engram.Notes.CrdtBloat.min_content_bytes/0 take NO sample — their Yjs framing " <>
              "divides to a large ratio that is not bloat. Its `_count` is therefore lower " <>
              "than the state_bytes/content_bytes counts, by design.",
          reporter_options: [buckets: [1, 2, 3, 5, 10, 25, 50, 100, 500]]
        ),
        distribution(
          metric_prefix ++ [:checkpoint_doc, :state_bytes],
          event_name: @doc_event,
          measurement: :state_bytes,
          description: "Encoded Yjs v1 state size per markdown checkpoint, before flatten.",
          reporter_options: [
            buckets: [1_000, 5_000, 10_000, 50_000, 100_000, 500_000, 1_000_000, 5_000_000]
          ]
        ),
        distribution(
          metric_prefix ++ [:checkpoint_doc, :content_bytes],
          event_name: @doc_event,
          measurement: :content_bytes,
          description: "Projected markdown size per checkpoint — the bloat_ratio denominator.",
          reporter_options: [
            buckets: [500, 1_000, 5_000, 10_000, 50_000, 100_000, 500_000]
          ]
        ),
        # The other half of the flatten gate. `should_flatten?/2` requires 1,000
        # distinct client IDs AND 500 KB; this says whether any real doc ever
        # approaches either.
        distribution(
          metric_prefix ++ [:checkpoint_doc, :client_count],
          event_name: @doc_event,
          measurement: :client_count,
          description: "Distinct client IDs in the doc state vector per markdown checkpoint.",
          reporter_options: [buckets: [1, 2, 5, 10, 25, 50, 100, 500, 1_000]]
        ),
        # #1706, the sweep half. The distributions above sample notes that were
        # OPENED, re-counting a frequently synced note on every open; these
        # gauges are one pass over every stored note
        # (`Engram.Workers.CrdtBloatSweep`), so they answer "how big is the
        # database and how much of it is bloat" rather than "what did traffic
        # look like".
        #
        # last_value, not distribution: the sweep already computed the
        # percentiles server-side over the true population. Re-bucketing them
        # would only lose precision, and a histogram of a handful of samples per
        # day is not a distribution.
        #
        # STALENESS CONTRACT — read before writing a query against these.
        #
        # A `last_value` gauge never expires: the reporter re-serves its last
        # sample on every scrape until something overwrites it. That is the
        # #1497 failure class (`config/runtime.exs`, the web-node Oban poll
        # gauges that froze a 494-job backlog for 40 minutes). Two consequences
        # specific to an event-driven gauge written by a cron job:
        #
        #   * Only the node that RAN the sweep holds a series. `Oban.Cron` is
        #     leader-gated, and `maintenance` does not run on `web`, so most
        #     nodes never export these at all — absent, not stale. Good.
        #   * Across a multi-task worker tier, consecutive runs can land on
        #     DIFFERENT tasks, leaving the previous one serving its last reading
        #     forever. Aggregate with `max by (instance)` or pick one instance —
        #     NEVER `sum`, which double-counts the byte totals.
        #
        # The sweep runs every 6 hours rather than daily mostly for this: an
        # ECS task replacement clears the table, and on a daily cadence that is
        # up to 24h of "No data" on every panel after each deploy.
        #
        # Assumes the default `PromEx.Storage.Core` reporter. Under
        # `PromEx.Storage.Peep` a MISSING measurement key records 1.0 rather
        # than being skipped, which would silently turn every sub-floor note
        # into a perfect 1.0 bloat ratio — the exact artifact
        # `Engram.Notes.CrdtBloat` exists to keep out. Do not set
        # `:storage_adapter` without revisiting the omit-vs-zero decision in
        # `CrdtCheckpoint.emit_doc_stats/3`.
        last_value(
          metric_prefix ++ [:state_sweep, :notes],
          event_name: @sweep_event,
          measurement: :notes,
          description:
            "Live notes (kind='note') in the database at the last sweep. The denominator for " <>
              "storage questions; `notes_with_state` is the subset that actually carries a " <>
              "CRDT snapshot."
        ),
        last_value(
          metric_prefix ++ [:state_sweep, :notes_with_state],
          event_name: @sweep_event,
          measurement: :notes_with_state,
          description:
            "Notes carrying a CRDT state snapshot. Below `notes` by the cohort migration " <>
              "20260706210000 NULLed and nothing re-seeds — those notes cost content bytes " <>
              "and no state bytes, so excluding them would overstate the bloat ratio."
        ),
        last_value(
          metric_prefix ++ [:state_sweep, :notes_measured],
          event_name: @sweep_event,
          measurement: :notes_measured,
          description:
            "Notes with state AND enough content to divide by — the denominator of every " <>
              "percentile below. The gap against `notes_with_state` is what the size floor " <>
              "keeps out of the percentiles. It is NOT purely empty notes: structural " <>
              "(.canvas) rows keep their data in Y.Maps and leave `content` untouched, so a " <>
              "fully populated board also lands in that gap. The sweep reads column lengths " <>
              "and cannot tell the two apart."
        ),
        last_value(
          metric_prefix ++ [:state_sweep, :bloat_ratio_p50],
          event_name: @sweep_event,
          measurement: :bloat_ratio_p50,
          description: "Median state/content ratio across every stored note."
        ),
        last_value(
          metric_prefix ++ [:state_sweep, :bloat_ratio_p90],
          event_name: @sweep_event,
          measurement: :bloat_ratio_p90,
          description: "p90 state/content ratio across every stored note."
        ),
        last_value(
          metric_prefix ++ [:state_sweep, :bloat_ratio_p99],
          event_name: @sweep_event,
          measurement: :bloat_ratio_p99,
          description: "p99 state/content ratio across every stored note."
        ),
        last_value(
          metric_prefix ++ [:state_sweep, :bloat_ratio_max],
          event_name: @sweep_event,
          measurement: :bloat_ratio_max,
          description:
            "Worst state/content ratio in the database. The single note the flatten gate " <>
              "in #1707 most needs to catch."
        ),
        last_value(
          metric_prefix ++ [:state_sweep, :notes_over_threshold],
          event_name: @sweep_event,
          measurement: :notes_over_threshold,
          description: "Notes whose state exceeds 5x their content — the #1707 tuning target."
        ),
        last_value(
          metric_prefix ++ [:state_sweep, :state_bytes_total],
          event_name: @sweep_event,
          measurement: :state_bytes_total,
          description:
            "Total decrypted-equivalent bytes of crdt_state across every live note. Paired " <>
              "with content_bytes_total this is the reclaimable-storage estimate the history " <>
              "epic (#609) needs before sizing anything. Aggregate with max, never sum."
        ),
        last_value(
          metric_prefix ++ [:state_sweep, :content_bytes_total],
          event_name: @sweep_event,
          measurement: :content_bytes_total,
          description:
            "Total decrypted-equivalent bytes of note content across every live note, " <>
              "including those carrying no CRDT state. Aggregate with max, never sum."
        ),
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

  @impl true
  def polling_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    metric_prefix = PromEx.metric_prefix(otp_app, :crdt)
    poll_rate = Keyword.get(opts, :crdt_poll_rate, 15_000)

    Polling.build(
      :engram_crdt_polling_metrics,
      poll_rate,
      {__MODULE__, :execute_room_metrics, []},
      [
        last_value(
          metric_prefix ++ [:rooms, :resident],
          event_name: @rooms_event,
          measurement: :resident,
          description:
            "CRDT rooms resident on THIS node. Compare against rooms_cap — sustained overshoot " <>
              "means the LRU is not keeping up. Aggregate with max by (instance), never sum. " <>
              "Overcounts, never undercounts: a room whose checkpoint timer died abnormally " <>
              "lingers until the next sweep prunes it."
        ),
        last_value(
          metric_prefix ++ [:rooms, :cap],
          event_name: @rooms_event,
          measurement: :cap,
          description:
            "The max_resident ceiling this node is enforcing. Shipped with the count so " <>
              "dashboards and alerts read a ratio instead of hardcoding the default."
        )
      ]
    )
  end

  @doc """
  Polled emitter for room residency. Reports the count and the ceiling it is
  judged against in ONE event, so the two can never be scraped from different
  moments and compared as if they were simultaneous.

  Cheap by design: an `:ets.info(_, :size)` and a config read. It deliberately
  does NOT prune dead entries first — see the moduledoc on why a scrape must not
  mutate the LRU's table.
  """
  @spec execute_room_metrics() :: :ok
  def execute_room_metrics do
    :telemetry.execute(
      @rooms_event,
      %{resident: CrdtRoomLru.resident_count(), cap: CrdtRoomLru.max_resident()},
      %{}
    )
  end
end
