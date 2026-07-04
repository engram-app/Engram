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
  """
  use GenServer

  alias Engram.Notes.CrdtCheckpoint

  require Logger

  @default_settle_ms 5_000
  @default_ceiling_ms 60_000
  @default_eager_ms 250

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
    note_id = Keyword.fetch!(opts, :note_id)

    cfg = Application.get_env(:engram, __MODULE__, [])
    settle_ms = Keyword.get(cfg, :settle_ms, @default_settle_ms)
    ceiling_ms = Keyword.get(cfg, :ceiling_ms, @default_ceiling_ms)
    eager_ms = Keyword.get(cfg, :eager_ms, @default_eager_ms)

    # Trap exits so we receive {:EXIT, room_pid, reason} as a handle_info
    # message instead of dying silently. This lets us flush or log before
    # exiting, and guarantees we exit on BOTH normal AND abnormal room exits.
    Process.flag(:trap_exit, true)
    Process.link(room_pid)

    state = %{
      room_pid: room_pid,
      user_id: user_id,
      vault_id: vault_id,
      note_id: note_id,
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
      settle_timer: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_info(:activity, state) do
    now = monotonic_ms()
    {delay, first_dirty_at} = compute_delay(state, now)

    # Cancel any existing settle timer and re-arm it.
    _ = if state.settle_timer, do: Process.cancel_timer(state.settle_timer)
    timer = Process.send_after(self(), :tick, delay)

    {:noreply,
     %{state | first_dirty_at: first_dirty_at, last_activity_at: now, settle_timer: timer}}
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
    {:stop, :normal, state}
  end

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

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp do_checkpoint(%{room_pid: room_pid} = state) do
    # Capture the row version BEFORE snapshotting the doc so it never exceeds the
    # version the snapshot reflects (#902 fence). A REST/MCP write committing
    # after this read bumps the version, so the fenced checkpoint write aborts
    # instead of reverting the committed content. nil on read failure → unfenced.
    captured_version = CrdtCheckpoint.current_version(state.user_id, state.note_id)
    doc = Yex.Sync.SharedDoc.get_doc(room_pid)

    CrdtCheckpoint.checkpoint(state.user_id, state.vault_id, state.note_id, doc,
      captured_version: captured_version
    )
  rescue
    err ->
      Logger.warning(
        "crdt checkpoint timer could not fetch doc note_id=#{state.note_id} reason=#{inspect(err)}",
        Engram.Logger.Metadata.with_category(:warning, :sync, note_id: state.note_id)
      )
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
