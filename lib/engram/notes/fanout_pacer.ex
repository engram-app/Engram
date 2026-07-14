defmodule Engram.Notes.FanoutPacer do
  @moduledoc """
  Paces the per-vault CRDT fan-out (`note_yjs_update`) so a large-vault genesis
  burst cannot starve a concurrent live-edit frame on the single `sync:` topic
  (engram-app/Engram#1002).

  Both emit sites (`CrdtPersistence.update_v1/4` delta, `CrdtDeliver.fanout_idle/3`
  full-state) call `emit/4` instead of `Broadcast.emit/3`. Classification is by
  per-note recency, done at the CALL SITE via a public ETS table so the live-edit
  hot path never enters this GenServer:

    * HOT  — the note had a fan-out within `hot_window_ms` (someone is actively
             editing it) → broadcast immediately, bypassing the pacer.
    * COLD — first touch / stale (bulk enrollment) → enqueued and drained per-vault
             at a bounded rate, room-free and never dropped.

  ponytail: single pacer process + one ETS table. Shard by vault (a Registry of
  per-vault pacers) only if fan-out throughput on one node ever measurably
  saturates this process; at launch scale one process is ample.
  """
  use GenServer

  alias Engram.Sync.Broadcast

  @table :fanout_hot

  @default_pacing_enabled true
  @default_hot_window_ms 2_000

  # Client -----------------------------------------------------------------

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Fan out `event`/`payload` on `topic` for `note_id`, paced when enabled.

  HOT (recent) notes broadcast inline; COLD notes are enqueued for paced drain.
  When pacing is disabled, always broadcasts inline (test/rollback path).
  """
  @spec emit(String.t(), String.t(), map(), String.t()) :: :ok
  def emit(topic, event, payload, note_id) do
    if pacing_enabled?() and cold?(note_id) do
      GenServer.cast(__MODULE__, {:enqueue, topic, event, payload})
    else
      Broadcast.emit(topic, event, payload)
    end

    :ok
  end

  @doc "Test helper: drop all queues and clear the hot table."
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  # Marks `note_id` seen now and returns whether it was COLD (not seen within the
  # hot window). Benign lookup/insert race across concurrent emits for one note
  # only ever mis-classifies a frame hot-vs-cold, never loses or corrupts it.
  defp cold?(note_id) do
    now = System.monotonic_time(:millisecond)

    cold =
      case :ets.lookup(@table, note_id) do
        [{^note_id, last}] -> now - last >= hot_window_ms()
        [] -> true
      end

    :ets.insert(@table, {note_id, now})
    cold
  end

  # Server -----------------------------------------------------------------

  @impl true
  def init(:ok) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{queues: %{}, draining: false}}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, %{state | queues: %{}, draining: false}}
  end

  # Config readers (evaluated at call time so tests can put_env) ------------

  defp pacing_enabled?,
    do: Application.get_env(:engram, :fanout_pacing_enabled, @default_pacing_enabled) == true

  defp hot_window_ms, do: pos_env(:fanout_hot_window_ms, @default_hot_window_ms)

  # ponytail: drain_batch/0 and drain_interval_ms/0 land in Task 2 alongside
  # the handle_cast/handle_info that call them — an unused private function is
  # a compile warning (this repo's CI runs --warnings-as-errors), so Task 1
  # keeps only the config readers it actually calls.

  defp pos_env(key, default) do
    case Application.get_env(:engram, key, default) do
      n when is_integer(n) and n > 0 -> n
      _ -> default
    end
  end
end
