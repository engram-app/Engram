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

  The `:fanout_hot` ETS table is periodically swept to evict stale entries and
  keep its size bounded.

  ponytail: single pacer process + one ETS table. Shard by vault (a Registry of
  per-vault pacers) only if fan-out throughput on one node ever measurably
  saturates this process; at launch scale one process is ample.
  """
  use GenServer

  alias Engram.Sync.Broadcast

  require Logger

  @table :fanout_hot

  @default_pacing_enabled true
  @default_hot_window_ms 2_000
  @default_drain_batch 20
  @default_drain_interval_ms 100
  @default_sweep_interval_ms 30_000
  @default_queue_warn_depth 2_000

  # Client -----------------------------------------------------------------

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Fan out `event`/`payload` on `topic` for `note_id`, paced when enabled.

  HOT (recent) notes broadcast inline; COLD notes are enqueued for paced drain.
  When pacing is disabled, always broadcasts inline (test/rollback path).
  """
  @spec emit(String.t(), String.t(), map(), String.t()) :: :ok
  def emit(topic, event, payload, note_id) do
    if test_dropped?(note_id) do
      :ok
    else
      if pacing_enabled?() and cold?(note_id) do
        GenServer.cast(__MODULE__, {:enqueue, topic, event, payload})
      else
        Broadcast.emit(topic, event, payload)
      end
    end

    :ok
  end

  @doc "Test helper: drop all queues and clear the hot table."
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc """
  Test-only: silently drop the next `n` fan-out emits for `note_id`.

  Simulates a lost live broadcast for the e2e seq-gap-heal proof: the client
  misses this op, the NEXT delivered op for the vault carries a later `seq`,
  and the client must detect it is behind and self-heal via
  `crdt_catchup_since`. Armed via the e2e harness `backend_rpc`; a no-op in
  normal operation (an unset `:persistent_term` read on the emit path).
  """
  @spec test_drop_next(String.t(), pos_integer()) :: :ok
  def test_drop_next(note_id, n \\ 1)
      when is_binary(note_id) and is_integer(n) and n > 0 do
    # An :atomics counter, not a bare integer: concurrent emits for the armed
    # note decrement atomically, so exactly n frames drop even under races
    # (review 2026-07-22 finding 4 — a read/put pair could drop n±1).
    ref = :atomics.new(1, signed: true)
    :atomics.put(ref, 1, n)
    :persistent_term.put({__MODULE__, :drop, note_id}, ref)
  end

  defp test_dropped?(note_id) do
    key = {__MODULE__, :drop, note_id}

    case :persistent_term.get(key, nil) do
      nil ->
        false

      ref ->
        left = :atomics.sub_get(ref, 1, 1)

        cond do
          left > 0 ->
            Logger.warning("fanout pacer TEST-DROP note_id=#{note_id} (#{left} more armed)")
            true

          left == 0 ->
            :persistent_term.erase(key)
            Logger.warning("fanout pacer TEST-DROP note_id=#{note_id} (0 more armed)")
            true

          true ->
            # Exhausted by a concurrent emit that will (or did) erase the key.
            false
        end
    end
  end

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
    _ =
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

    _ = Process.send_after(self(), :sweep, sweep_interval_ms())
    {:ok, %{queues: %{}, draining: false}}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, %{state | queues: %{}, draining: false}}
  end

  @impl true
  def handle_cast({:enqueue, topic, event, payload}, %{queues: queues} = state) do
    q = Map.get(queues, topic, :queue.new())
    queues = Map.put(queues, topic, :queue.in({event, payload}, q))
    {:noreply, ensure_draining(%{state | queues: queues})}
  end

  @impl true
  def handle_info(:drain, state) do
    queues =
      state.queues
      |> Enum.map(fn {topic, q} -> {topic, drain_topic(topic, q, drain_batch())} end)
      |> Enum.reject(fn {_topic, q} -> :queue.is_empty(q) end)
      |> Map.new()

    depths = Enum.map(queues, fn {_topic, q} -> :queue.len(q) end)
    total = Enum.sum(depths)
    max_depth = Enum.max([0 | depths])

    :telemetry.execute(
      [:engram, :fanout_pacer, :drain],
      %{queued: total, max_topic_depth: max_depth, topics: map_size(queues)},
      %{}
    )

    if max_depth >= queue_warn_depth() do
      Logger.warning(
        "fanout pacer queue deep max_topic_depth=#{max_depth} total=#{total} topics=#{map_size(queues)}"
      )
    end

    if map_size(queues) > 0 do
      _ = Process.send_after(self(), :drain, drain_interval_ms())
      {:noreply, %{state | queues: queues, draining: true}}
    else
      {:noreply, %{state | queues: %{}, draining: false}}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.monotonic_time(:millisecond) - hot_window_ms()
    # Delete every note whose last-seen time is at/older than the cutoff.
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:"=<", :"$1", cutoff}], [true]}])
    _ = Process.send_after(self(), :sweep, sweep_interval_ms())
    {:noreply, state}
  end

  # Pop up to `n` frames off `q` and broadcast each on `topic` (per-vault FIFO).
  defp drain_topic(topic, q, n) when n > 0 do
    case :queue.out(q) do
      {{:value, {event, payload}}, q2} ->
        Broadcast.emit(topic, event, payload)
        drain_topic(topic, q2, n - 1)

      {:empty, q2} ->
        q2
    end
  end

  defp drain_topic(_topic, q, _n), do: q

  # Arm the drain timer exactly once; subsequent enqueues ride the running loop.
  defp ensure_draining(%{draining: true} = state), do: state

  defp ensure_draining(state) do
    _ = Process.send_after(self(), :drain, drain_interval_ms())
    %{state | draining: true}
  end

  # Config readers (evaluated at call time so tests can put_env) ------------

  defp pacing_enabled?,
    do: Application.get_env(:engram, :fanout_pacing_enabled, @default_pacing_enabled) == true

  defp hot_window_ms, do: pos_env(:fanout_hot_window_ms, @default_hot_window_ms)
  defp drain_batch, do: pos_env(:fanout_drain_batch, @default_drain_batch)
  defp drain_interval_ms, do: pos_env(:fanout_drain_interval_ms, @default_drain_interval_ms)
  defp sweep_interval_ms, do: pos_env(:fanout_sweep_interval_ms, @default_sweep_interval_ms)
  defp queue_warn_depth, do: pos_env(:fanout_queue_warn_depth, @default_queue_warn_depth)

  defp pos_env(key, default) do
    case Application.get_env(:engram, key, default) do
      n when is_integer(n) and n > 0 -> n
      _ -> default
    end
  end
end
