defmodule Engram.Notes.CrdtRoomLru do
  @moduledoc """
  Resident-room backstop for #1152: bounds how many drain-enabled CRDT rooms
  stay resident on THIS node, evicting the least recently active.

  ## Why idle-exit is not enough

  The idle drain (`CrdtCheckpointTimer`) bounds rooms that go QUIET. It does
  nothing for a room that is continuously active — and #1149 measured **7.91 MB
  resident per 10k-note vault** against a 1024 MB task, so a pathological mix of
  busy vaults still pins memory. This is the pressure valve for that case.

  ## It drains, it never kills

  Eviction broadcasts on the room's drain topic, exactly as the idle timer does:
  observers evict their cached pid and unobserve, and the last unobserve trips
  `auto_exit` → `terminate/2` → `unbind` → checkpoint. Killing a room instead
  would silently eat the next `sync_update` (a `GenServer.cast` to a dead pid
  returns `:ok`), which is the whole reason the drain exists.

  Note the LRU deliberately **bypasses `CrdtCheckpointTimer.idle?/2`**: evicting
  rooms that are *not* idle is its entire job. That is precisely why it must go
  through the safe release path rather than inventing a second one.

  ## Only drain-enabled rooms are tracked

  `touch/2` is called from the checkpoint timer ONLY when `idle_exit_ms` is set,
  so a note room never enters the table and can never be evicted. That keeps the
  whole feature inert until #1150's index room opts in.

  Every tracked pid is LOCAL: a room's timer is started on the same node as the
  room (`CrdtDoc.start_link`), so `Process.alive?/1` — which raises on remote
  pids — is safe here. Each node bounds its own residency, which is correct
  because memory is per-node.

  ## Config

      config :engram, Engram.Notes.CrdtRoomLru,
        max_resident: 64,
        sweep_interval_ms: 30_000

  `max_resident` wants tuning against real index-doc sizes once #1150 exists —
  #1146's arithmetic says ~128 resident rooms would consume an entire task, so
  the default deliberately sits well under that.
  """
  use GenServer

  alias Engram.Notes.CrdtRegistry

  require Logger

  @table :crdt_room_lru
  @default_max_resident 64
  @default_sweep_interval_ms 30_000
  @drain_event [:engram, :crdt, :room_drain]

  # Client -------------------------------------------------------------------

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Record that `note_id`'s room is resident and active as of now. Called from the
  checkpoint timer on start and on every write, and cheap by design: a single
  ETS insert on the hot path, no GenServer round-trip.
  """
  @spec touch(String.t(), pid(), String.t()) :: :ok
  def touch(note_id, room_pid, vault_id) do
    :ets.insert(@table, {note_id, room_pid, vault_id, System.monotonic_time(:millisecond)})
    :ok
  end

  @doc "Drop a room's entry (its room exited)."
  @spec forget(String.t()) :: :ok
  def forget(note_id) do
    :ets.delete(@table, note_id)
    :ok
  end

  @doc "Live rooms currently tracked on this node."
  @spec resident_count() :: non_neg_integer()
  def resident_count, do: :ets.info(@table, :size)

  @doc """
  Prune dead entries, then drain down to `cap`. Synchronous so tests need not
  wait out the sweep interval.
  """
  @spec sweep(pos_integer() | nil) :: :ok
  def sweep(cap \\ nil), do: GenServer.call(__MODULE__, {:sweep, cap})

  @doc false
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc """
  Which note_ids to evict: the oldest `length(entries) - cap`, least recently
  active first. Pure, so the policy is testable without rooms or ETS.
  """
  @spec select_evictions([{String.t(), pid(), String.t(), integer()}], non_neg_integer()) ::
          [String.t()]
  def select_evictions(entries, cap) do
    excess = length(entries) - cap

    if excess <= 0 do
      []
    else
      entries
      |> Enum.sort_by(fn {_id, _pid, _vault, last} -> last end)
      |> Enum.take(excess)
      |> Enum.map(fn {id, _pid, _vault, _last} -> id end)
    end
  end

  # Server -------------------------------------------------------------------

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

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:sweep, cap}, _from, state) do
    do_sweep(cap || max_resident())
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    do_sweep(max_resident())
    schedule_sweep()
    {:noreply, state}
  end

  # Private ------------------------------------------------------------------

  defp do_sweep(cap) do
    live = prune_dead()
    evict(select_evictions(live, cap), cap, length(live))
  end

  # A room that exited between sweeps still holds an entry. Prune BEFORE
  # selecting, or corpses count toward residency and healthy rooms get evicted
  # to free memory that nothing is using.
  defp prune_dead do
    @table
    |> :ets.tab2list()
    |> Enum.filter(fn {note_id, pid, _vault, _last} ->
      if Process.alive?(pid) do
        true
      else
        forget(note_id)
        false
      end
    end)
  end

  defp evict([], _cap, _resident), do: :ok

  defp evict(note_ids, cap, resident) do
    # Never silent: an LRU eviction means the idle drain alone was not keeping
    # up, which is a capacity signal and not routine.
    Logger.warning(
      "crdt room LRU evicting #{length(note_ids)} room(s) — resident=#{resident} cap=#{cap}",
      Engram.Logger.Metadata.with_category(:warning, :sync)
    )

    for note_id <- note_ids do
      case :ets.lookup(@table, note_id) do
        [{^note_id, pid, vault_id, _last}] ->
          # Same broadcast the idle timer sends: observers let go, auto_exit
          # checkpoints. Counted under its own phase so a dashboard can tell
          # memory-pressure eviction from an ordinary idle drain.
          _ =
            Phoenix.PubSub.broadcast(
              Engram.PubSub,
              CrdtRegistry.drain_topic(vault_id),
              {:crdt_room_drain, pid}
            )

          :telemetry.execute(@drain_event, %{count: 1}, %{phase: :lru_evicted})

        [] ->
          :ok
      end
    end

    :ok
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, sweep_interval_ms())

  defp cfg, do: Application.get_env(:engram, __MODULE__, [])
  defp max_resident, do: Keyword.get(cfg(), :max_resident) || @default_max_resident
  defp sweep_interval_ms, do: Keyword.get(cfg(), :sweep_interval_ms) || @default_sweep_interval_ms
end
