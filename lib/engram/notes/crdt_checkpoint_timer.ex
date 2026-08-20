defmodule Engram.Notes.CrdtCheckpointTimer do
  @moduledoc """
  Per-room debounced checkpoint timer.

  Linked to the room's `Yex.Sync.SharedDoc` process (dies when the room
  exits). On each `:tick`, reads the live doc via `Yex.Sync.SharedDoc.get_doc/1`
  and calls `CrdtCheckpoint.checkpoint/4`. The timer resets on `:activity`
  (sent by the room on every `update_v1` callback) — snapshots only fire after
  the note has been quiet for `settle_ms` milliseconds, bounded by a
  `ceiling_ms` hard cap so a continuously-edited note still gets flushed.

  ## Config

  Override in `config/test.exs` for timer-friendly tests:

      config :engram, Engram.Notes.CrdtCheckpointTimer,
        settle_ms: 100,
        ceiling_ms: 500,
        eager_ms: 20

  Defaults: settle 5 000 ms / ceiling 60 000 ms / eager 250 ms.

  ## Eager first flush

  A plain settle/ceiling debounce means the plaintext `notes.content`
  projection — which only updates on a checkpoint — stays stale for up to
  `settle_ms` (5 s) after an edit, and longer under sustained typing. Every
  non-CRDT reader (REST `/api/notes`, the web app, the search index, a second
  device seeding a fresh room) then sees stale content for seconds. So the
  FIRST edit after a genuine idle gap (>= `settle_ms`, i.e. the note had gone
  quiet and flushed) schedules an `eager_ms` (~250 ms) flush instead of waiting
  the full settle — content materializes promptly. Sustained editing thereafter
  stays settle-debounced and ceiling-capped, so there is still exactly ONE
  checkpoint per dirty streak (no per-keystroke churn, no double flush, no
  version/seq thrash). The cheap O(append) `update_v1` hot path is untouched.

  ## Idle drain (`idle_exit_ms`, #1152)

  ON by default (`@default_idle_exit_ms`), for every note room, in every
  environment. Resolution is: per-room opt, then this module's app config, then
  that default. Pass `0` (or configure `nil`) to disable it for a room.

  It used to be opt-in and `nil` by default, which meant the drain armed only
  where something set it — CI — and prod ran with no room bound at all. On
  2026-08-18 that let a 1.7k-file vault upload leave ~2000 rooms resident
  (process count 757 -> 2744, process memory 41 MB -> 324 MB against an 820 MB
  container limit) with `crdt_room_drain_total` at 0/0 the whole window. A
  residency bound that defaults off is unbound in exactly the fleets that need
  it most. `CrdtIndexDoc` already reached this conclusion independently — see its
  "never to `nil`. There is no 'drain disabled' mode".

  `CRDT_IDLE_EXIT_MS` (`ci/compose.yml`) still overrides it fleet-wide in
  CI/e2e — on purpose, so the Obsidian suite exercises the drain against the real
  client at a timescale a test can observe. Note that env var is CI-gated
  (`RuntimeConfig.ci_gated_int_override/2`) and is therefore NOT how production
  gets a value; setting it in a task definition is a silent no-op.

  `auto_exit` ends a room when its LAST OBSERVER leaves. That bounds a note
  room, which is observed only while the note is open — but a per-vault index
  room (#1150) is observed for as long as any client is connected, making its
  lifetime session-length and its residency a function of concurrent
  connections rather than mutation rate. #1149 measured 7.91 MB resident per
  10k-note vault, which misses the target by two orders of magnitude.

  When `idle_exit_ms` is set, a room that has seen no `:activity` for that long
  broadcasts `{:crdt_room_drain, room_pid}` on `CrdtRegistry.drain_topic/1`.
  Observers evict their cached pid and unobserve; the last unobserve trips the
  EXISTING `auto_exit`, whose `terminate/2` runs `CrdtPersistence.unbind/3` and
  checkpoints.

  It does NOT stop the room itself, and that distinction is the whole design.
  A client edit is a `sync_update` frame, which y_ex dispatches as a
  `GenServer.cast` (`deps/y_ex/lib/server/doc_server_worker.ex:26`) — a cast to
  a dead pid returns `:ok` and drops the edit. Stopping a room out from under an
  attached observer would therefore turn a timer into silent data loss.
  Draining makes observers let go FIRST, so a frame either lands on the live
  room or re-resolves a fresh one, and the exit falls out of machinery that
  already exists.

  The broadcast re-arms, so an observer that ignores a drain (a stale client, a
  wedged channel) is asked again rather than pinning the room forever.
  """
  use GenServer

  alias Engram.{Accounts, Repo}
  alias Engram.Logger.Metadata
  alias Engram.Notes.{CrdtBridge, CrdtCheckpoint, CrdtPersistence, CrdtRegistry, CrdtRoomLru}

  require Logger

  @default_settle_ms 5_000
  @default_ceiling_ms 60_000
  @default_eager_ms 250

  # No activity for this long and the room asks its observers to let go, after
  # which the existing auto_exit stops it. 5 min is deliberately conservative:
  # the cost of draining a room someone still wants is one re-handshake on their
  # next keystroke. See the resolution in init/1 for why this defaults ON.
  @default_idle_exit_ms 300_000

  # Cap on the idle-drain re-ask multiplier (see drain_delay/1).
  @max_drain_backoff 8

  # Percent of the drain delay added as random jitter (see jittered_drain_delay/1).
  @drain_jitter_pct 25

  @drain_event [:engram, :crdt, :room_drain]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start a timer linked to `room_pid`. Linked — if the room exits the timer
  exits too, and vice versa.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Signal recent write activity. Resets the settle timer. No-op if already
  past the ceiling (the flush will happen regardless on next tick).
  """
  @spec notify_activity(pid()) :: :ok
  def notify_activity(pid) when is_pid(pid) do
    send(pid, :activity)
    :ok
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    room_pid = Keyword.fetch!(opts, :room_pid)
    user_id = Keyword.fetch!(opts, :user_id)
    vault_id = Keyword.fetch!(opts, :vault_id)

    # `:note` (default) keys off note_id and checkpoints on every tick.
    # `:index` keys off vault_id and NEVER ticks a checkpoint — see
    # `do_checkpoint/1`. Defaulting keeps every existing note call site literal.
    mode = Keyword.get(opts, :mode, :note)
    room_key = if mode == :index, do: vault_id, else: Keyword.fetch!(opts, :note_id)

    cfg = Application.get_env(:engram, __MODULE__, [])
    settle_ms = Keyword.get(cfg, :settle_ms, @default_settle_ms)
    ceiling_ms = Keyword.get(cfg, :ceiling_ms, @default_ceiling_ms)
    eager_ms = Keyword.get(cfg, :eager_ms, @default_eager_ms)
    # Per-room opt wins, then fleet config, then the built-in default. Set either
    # to 0 to disable the drain for a room.
    #
    # This defaults ON. It used to default to nil (disabled), which meant the
    # drain shipped in #1382 was armed only where something set it — CI — and a
    # room in prod lived until its last observer left. On 2026-08-18 a 1.7k-file
    # vault upload left ~2000 rooms resident on 0.5-vCPU tasks (process count
    # 757 -> 2744, process memory 41 MB -> 324 MB against an 820 MB limit) with
    # `crdt_room_drain_total` at 0/0 for the entire window.
    #
    # Defaulting off is the wrong shape for a residency bound: every environment
    # that forgets to set it is unbounded, and the one that most needs the bound
    # (a real fleet under real load) is the least likely to have it. Rooms are
    # ephemeral by design — a drained room checkpoints to Postgres and is
    # re-created on the next frame — so the cost of a drain that wasn't needed is
    # one re-handshake, not lost data.
    idle_exit_ms =
      Keyword.get(opts, :idle_exit_ms) ||
        Keyword.get(cfg, :idle_exit_ms, @default_idle_exit_ms)

    # Trap exits so we receive {:EXIT, room_pid, reason} as a handle_info
    # message instead of dying silently. This lets us flush or log before
    # exiting, and guarantees we exit on BOTH normal AND abnormal room exits.
    Process.flag(:trap_exit, true)
    Process.link(room_pid)

    state = %{
      room_pid: room_pid,
      user_id: user_id,
      vault_id: vault_id,
      mode: mode,
      room_key: room_key,
      settle_ms: settle_ms,
      ceiling_ms: ceiling_ms,
      eager_ms: eager_ms,
      # Monotonic ms when the current dirty streak began (the ceiling anchor) —
      # nil between checkpoints.
      first_dirty_at: nil,
      # Monotonic ms of the previous activity event — nil until first activity.
      # Used to detect a genuine idle gap (>= settle) that makes the next edit
      # eager-eligible. NOT reset on flush, so typing that resumes right after a
      # ceiling/settle flush is correctly seen as still-active (not eager).
      last_activity_at: nil,
      settle_timer: nil,
      # nil/0 = drain disabled. Rare: this defaults ON, so it means an
      # explicit opt-out rather than the old fleet-wide default.
      idle_exit_ms: idle_exit_ms,
      idle_timer: nil,
      # Consecutive drains broadcast with nobody acting on them. Backs the
      # re-ask off so an unreachable observer (netsplit, wedged channel) cannot
      # broadcast at a fixed rate forever. Reset by any activity.
      drain_attempts: 0
    }

    # Armed at init, not only on activity: a room that spins for a handshake and
    # is never written to (the common index-room case — connect, sync, go quiet)
    # must still drain.
    {:ok, touch_lru(arm_idle(state))}
  end

  @impl true
  def handle_info(:activity, state) do
    now = monotonic_ms()
    {delay, first_dirty_at} = compute_delay(state, now)

    # Cancel any existing settle timer and re-arm it. Not armed at all in
    # :index mode — `do_checkpoint/1` is a no-op there, so a settle tick would
    # be a timer scheduled to do nothing.
    _ = if state.settle_timer, do: Process.cancel_timer(state.settle_timer)
    timer = if state.mode == :index, do: nil, else: Process.send_after(self(), :tick, delay)

    {:noreply,
     touch_lru(
       arm_idle(%{
         state
         | first_dirty_at: first_dirty_at,
           last_activity_at: now,
           settle_timer: timer,
           drain_attempts: 0
       })
     )}
  end

  # The room has been quiet for `idle_exit_ms`. Ask its observers to let go; the
  # last unobserve trips auto_exit, which checkpoints via unbind on terminate.
  # We deliberately do NOT stop the room here — see the moduledoc.
  @impl true
  def handle_info(:idle_drain, state) do
    # Re-check idleness against OBSERVED activity rather than trusting the timer
    # bookkeeping. `Process.cancel_timer/1` cannot un-send a message that already
    # reached the mailbox, so an `:idle_drain` can be queued just before an
    # `:activity` and still be processed after it — draining a room the user is
    # actively editing. Lossless (unbind checkpoints) but it churns the room and
    # contradicts the whole point of re-arming, so gate on the real clock.
    state =
      if idle?(state, monotonic_ms()) do
        phase =
          case Phoenix.PubSub.broadcast(
                 Engram.PubSub,
                 CrdtRegistry.drain_topic(state.vault_id),
                 {:crdt_room_drain, state.room_pid}
               ) do
            :ok ->
              if state.drain_attempts == 0, do: :requested, else: :reasked

            {:error, reason} ->
              # Transient by nature — the re-arm below asks again, and the
              # attempt still counts so a persistently broken broadcast backs
              # off rather than hammering. Logged because a room that can never
              # ask its observers to let go is exactly the unbounded-residency
              # case the drain exists to prevent.
              #
              # Its OWN phase: nothing was asked, so counting it as :requested
              # would report an ask that never went out — and `requested` is the
              # denominator an operator reads this metric through.
              Logger.warning(
                "crdt drain broadcast failed: #{Metadata.safe_reason(reason)}",
                Engram.Logger.Metadata.with_category(:warning, :sync, room_key: state.room_key)
              )

              :request_failed
          end

        :telemetry.execute(@drain_event, %{count: 1}, %{phase: phase})

        %{state | drain_attempts: state.drain_attempts + 1}
      else
        state
      end

    # Re-arm either way: an observer that ignored the drain gets asked again
    # instead of pinning the room forever — but at a backed-off interval, so an
    # unreachable observer cannot hold a fixed broadcast rate indefinitely.
    {:noreply, arm_idle(%{state | idle_timer: nil})}
  end

  @impl true
  def handle_info(:tick, state) do
    do_checkpoint(state)

    # Reset dirty anchor — we just flushed.
    {:noreply, %{state | first_dirty_at: nil, settle_timer: nil}}
  end

  # Room exited — we trap exits (Process.flag(:trap_exit, true) is set in init/1),
  # so the linked room's exit is converted to a {:EXIT, pid, reason} message
  # rather than an immediate process death. This lets us perform a clean stop
  # for both normal and abnormal room exits without leaving an orphaned timer.
  @impl true
  def handle_info({:EXIT, _room_pid, _reason}, state) do
    if state.idle_exit_ms, do: CrdtRoomLru.forget(state.room_key)
    {:stop, :normal, state}
  end

  # Only drain-ENABLED rooms are tracked for eviction, so a room with the drain
  # explicitly off can never be LRU-evicted either. Since the drain now defaults
  # ON, that is the opt-out case — it is NOT prod, where every note room is
  # enrolled. CI/e2e additionally overrides the window via `CRDT_IDLE_EXIT_MS`.
  #
  # The guard must match `arm_idle/1`'s exactly. It used to match only `nil`,
  # so `idle_exit_ms: 0` — which `arm_idle/1` treats as disabled — enrolled the
  # room in the LRU and left it evictable: half-disabled, in the one direction
  # nothing would notice, since eviction bypasses `idle?/2` on purpose.
  defp touch_lru(%{idle_exit_ms: ms} = state) when is_integer(ms) and ms > 0 do
    CrdtRoomLru.touch(state.room_key, state.room_pid, state.vault_id)
    state
  end

  defp touch_lru(state), do: state

  @doc """
  Pure scheduling decision: given the timer `state` and a monotonic `now`,
  return `{delay_ms, first_dirty_at}` for the next checkpoint tick.

  - `first_dirty_at` anchors the dirty streak (the ceiling clock); it is set on
    the first activity after a checkpoint and threaded back into state.
  - The base delay is the settle window, capped by the remaining ceiling budget
    so a continuously-edited note still flushes.
  - When this activity follows a genuine idle gap (no prior activity, or the gap
    since the last one is at least `settle_ms` — meaning the note had gone quiet
    and already flushed), the first flush of the new streak is pulled forward to
    `eager_ms` so the plaintext projection materializes promptly. Sustained
    editing (gap < settle) keeps the settle/ceiling debounce.
  """
  @spec compute_delay(map(), integer()) :: {non_neg_integer(), integer()}
  def compute_delay(state, now) do
    first_dirty_at = state.first_dirty_at || now
    remaining_until_ceiling = state.ceiling_ms - (now - first_dirty_at)
    base = min(state.settle_ms, remaining_until_ceiling)

    quiet_before? =
      is_nil(state.last_activity_at) or now - state.last_activity_at >= state.settle_ms

    delay = if quiet_before?, do: min(base, state.eager_ms), else: base

    {max(0, delay), first_dirty_at}
  end

  @doc """
  Whether the room has genuinely been quiet for its full `idle_exit_ms` as of
  monotonic `now` — the gate on the drain broadcast.

  Checked against OBSERVED activity rather than timer bookkeeping because
  `Process.cancel_timer/1` cannot un-send a message already in the mailbox: an
  `:idle_drain` can be queued just before an `:activity` and still be handled
  after it. Without this gate that races into draining a room the user is
  actively editing — lossless (unbind checkpoints) but pure churn, and the exact
  thing re-arming exists to prevent.

  A room that has never seen a write is idle by definition. That is the ordinary
  index-room shape: spin, handshake, go quiet, never written to.
  """
  @spec idle?(map(), integer()) :: boolean()
  def idle?(%{last_activity_at: nil}, _now), do: true

  def idle?(state, now), do: now - state.last_activity_at >= state.idle_exit_ms

  @doc """
  How long to wait before the next `:idle_drain`, given how many consecutive
  drains have already gone unanswered.

  The first ask is at the plain `idle_exit_ms`. Each unanswered one lengthens the
  next by a further multiple, capped at #{@max_drain_backoff}x, so an observer
  that can never act (netsplit, wedged channel) degrades to an occasional re-ask
  rather than broadcasting at a fixed rate for the life of the room. Any
  `:activity` resets the count, so a room that goes quiet again drains promptly.
  """
  # Guarded on integers rather than widening the spec to number(): the result
  # feeds Process.send_after/3, which REQUIRES a non-negative integer, so a
  # float idle_exit_ms is a runtime crash rather than a typing inconvenience.
  # arm_idle/1 already enforces this at the only production call site; the guard
  # makes the contract hold for the public function too.
  @spec drain_delay(map()) :: pos_integer()
  def drain_delay(%{idle_exit_ms: ms, drain_attempts: attempts})
      when is_integer(ms) and ms > 0 and is_integer(attempts) do
    ms * min(attempts + 1, @max_drain_backoff)
  end

  @doc """
  `drain_delay/1` plus up to #{@drain_jitter_pct}% of random spread.

  Without this, drains synchronize. `auto_exit` fires on user behaviour, so
  exits spread themselves out naturally — but idle timers are armed when the
  room STARTS, so every room started in the same burst (a deploy, a reconnect
  storm) would drain in the same instant and fire a synchronized checkpoint
  storm. That is the 2026-07-09 pool-exhaustion shape; `CheckpointGate` +
  the Oban overflow would absorb it, but designing the spike in and leaning on
  the shock absorber is backwards.

  Jitter is ADDITIVE only. `idle_exit_ms` is a floor — a minimum quiet period
  before a room may be taken away — and shortening it would drain rooms that
  have not actually been idle long enough.
  """
  @spec jittered_drain_delay(map()) :: pos_integer()
  def jittered_drain_delay(state) do
    base = drain_delay(state)
    base + :rand.uniform(max(div(base * @drain_jitter_pct, 100), 1)) - 1
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # No-op when the drain is disabled (`idle_exit_ms: nil`), which is every note
  # room. Cancels first so activity genuinely postpones the drain rather than
  # stacking timers.
  # Guarded on a POSITIVE integer, so `nil` (every note room), `0`, and any
  # nonsense value all land on the no-op clause. A zero window would otherwise
  # re-arm at 0ms and spin the drain broadcast in a tight loop.
  defp arm_idle(%{idle_exit_ms: ms} = state) when is_integer(ms) and ms > 0 do
    _ = if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    %{state | idle_timer: Process.send_after(self(), :idle_drain, jittered_drain_delay(state))}
  end

  defp arm_idle(state), do: state

  # An index room's checkpoint MUST come from `CrdtIndexPersistence.unbind/3`,
  # never from a tick here. Only the room's own persistence state knows which
  # tail rows failed to replay (`:unfolded_ids`), and a checkpoint that prunes
  # without that list deletes exactly the claims the tail log exists to protect
  # (#1391). So the drain is the whole mechanism for this room: observers let
  # go, `auto_exit` fires, and `terminate/2` checkpoints with the right state.
  defp do_checkpoint(%{mode: :index}), do: :ok

  defp do_checkpoint(%{room_pid: room_pid} = state) do
    # Capture the row version BEFORE snapshotting the doc so it never exceeds the
    # version the snapshot reflects (#902 fence). A REST/MCP write committing
    # after this read bumps the version, so the fenced checkpoint write aborts
    # instead of reverting the committed content.
    #
    # nil on read failure is NOT an unfenced write (it was, before #1360). The
    # version CAS is layered ON TOP of `snapshot_fence/2`, which applies to every
    # checkpoint write path unconditionally. nil just drops the extra layer.
    #
    # This read stays FIRST even though the fold below now adds DB work between
    # it and the write, widening the CAS window. Moving it after the fold would
    # invert the fence: the version could then post-date the doc state we
    # encoded, so a REST write landing in the gap would MATCH on version while
    # the snapshot lacks it, and the CAS would let a clobber through. A wider
    # window only costs extra aborts, which are safe and retried on the next
    # tick. Wrong order costs content.
    captured_version = CrdtCheckpoint.current_version(state.user_id, state.room_key)
    doc = Yex.Sync.SharedDoc.get_doc(room_pid)

    # Prune EXACTLY what this snapshot folded (#1146 spec 0a).
    #
    # Passing no `:prune_ids` takes the WATERMARK branch, which deletes every
    # tail row at or below the watermark whether or not the snapshotted doc
    # folded it. That is safe only while the room is the SOLE tail writer, so
    # its doc provably reflects every row that exists — a property of who may
    # append, not of the checkpoint. A row appended by anyone else after the
    # room bound is in no snapshot and would be deleted unfolded: gone from the
    # tail AND absent from crdt_state.
    #
    # This is the rule #1391 already established for the index room ("a
    # checkpoint that prunes without that list deletes exactly the claims the
    # tail log exists to protect"), which sidesteps it by never checkpointing
    # from a tick. A note room ticks, so it has to fold instead.
    #
    # Fold the durable tail into a transient doc seeded from the room's ENCODED
    # STATE, never from its projected text: a doc rebuilt from text is a
    # different Yjs lineage and unions into a duplicated body. The room's own
    # doc is a NIF resource owned by the room process, so it is never mutated
    # from here.
    # A deleted user is an expected lifecycle state (vault purge), not an error —
    # same call and same verdict as `Workers.CheckpointNote.rebuild_detached/3`.
    # `get_user!/1` would raise into the rescue below and log a "read failure"
    # that never happened.
    case Accounts.get_user(state.user_id) do
      nil ->
        :ok

      user ->
        {:ok, encoded} = Yex.encode_state_as_update(doc)
        {:ok, folded} = CrdtBridge.doc_from_state(encoded)

        # `replay_tail/3` issues a BARE `Repo.all` — it sets no tenant of its
        # own. Every other caller supplies one (`bind/3`,
        # `CheckpointNote.rebuild_detached/3`, `CrdtChannel.fold_row_and_tail/4`
        # all run it under `with_tenant`). Without one, RLS returns no rows,
        # `prune_ids` comes back empty, and compaction silently stops — the
        # tail grows forever and nothing reports it.
        {:ok, prune_ids} =
          Repo.with_tenant(state.user_id, fn ->
            CrdtPersistence.replay_tail(folded, user, state.room_key)
          end)

        CrdtCheckpoint.checkpoint(state.user_id, state.vault_id, state.room_key, folded,
          captured_version: captured_version,
          prune_ids: prune_ids
        )
    end
  rescue
    err -> log_read_failure(state, err)
  catch
    # `get_doc/1` is a GenServer.call, and a call to a process that terminates
    # mid-call EXITS rather than raising — `rescue` never sees it, so the timer
    # died here instead of degrading the way the comment above intends.
    #
    # The race is routine: the room stops with a `:tick` already in our mailbox,
    # and the `{:EXIT, room_pid, _}` that stops us cleanly is queued behind it.
    # There is nothing to checkpoint once the room is gone — the doc it held is
    # what we were trying to read — so falling through is the correct outcome,
    # and the EXIT message right behind this tick shuts us down in order.
    :exit, reason -> log_exit_failure(state, reason)
  end

  # Two arms, two shapes, two helpers. One helper taking both was a REGRESSION
  # shipped in this series and caught in review: `rescue` hands over an
  # exception STRUCT, which `safe_exit_reason/1` has no clause for and renders
  # `"unknown"`, while the catch arm wrapped its reason in `{:exit, reason}`,
  # which matches the `{tag, _}` clause and renders the constant `":exit"`.
  # Both arms logged a fixed string instead of the failure — the exact
  # diagnostic loss this module's rescue exists to avoid, dressed up as safety.
  defp log_read_failure(state, err), do: emit_read_failure(state, Metadata.safe_reason(err))

  # Unwrapped: an exit reason from a dead GenServer.call is `{:noproc, {...}}`
  # or `{:shutdown, ...}`, and `safe_exit_reason/1` pulls the tag off it.
  # Wrapping it first threw that tag away.
  defp log_exit_failure(state, reason),
    do: emit_read_failure(state, Metadata.safe_exit_reason(reason))

  defp emit_read_failure(state, reason) do
    Logger.warning(
      "crdt checkpoint timer could not fetch doc room_key=#{state.room_key} reason=#{reason}",
      Engram.Logger.Metadata.with_category(:warning, :sync, room_key: state.room_key)
    )
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
