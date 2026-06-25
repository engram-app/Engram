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
        ceiling_ms: 500

  Defaults: settle 5 000 ms / ceiling 60 000 ms.
  """
  use GenServer

  alias Engram.Notes.CrdtCheckpoint

  require Logger

  @default_settle_ms 5_000
  @default_ceiling_ms 60_000

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
      # Monotonic ms of the last activity event — nil until first activity.
      first_dirty_at: nil,
      settle_timer: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_info(:activity, state) do
    now = monotonic_ms()

    # Record the ceiling anchor on the first dirty event after a checkpoint.
    first_dirty_at = state.first_dirty_at || now

    # Cancel any existing settle timer and re-arm it.
    if state.settle_timer, do: Process.cancel_timer(state.settle_timer)

    remaining_until_ceiling = state.ceiling_ms - (now - first_dirty_at)

    # Schedule the tick at whichever comes first: settle idle or ceiling.
    delay = max(0, min(state.settle_ms, remaining_until_ceiling))
    timer = Process.send_after(self(), :tick, delay)

    {:noreply, %{state | first_dirty_at: first_dirty_at, settle_timer: timer}}
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

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp do_checkpoint(%{room_pid: room_pid} = state) do
    doc = Yex.Sync.SharedDoc.get_doc(room_pid)
    CrdtCheckpoint.checkpoint(state.user_id, state.vault_id, state.note_id, doc)
  rescue
    err ->
      Logger.warning(
        "crdt checkpoint timer could not fetch doc note_id=#{state.note_id} reason=#{inspect(err)}",
        Engram.Logger.Metadata.with_category(:warning, :sync, note_id: state.note_id)
      )
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
