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

  `touch/3` is called from the checkpoint timer ONLY when `idle_exit_ms` is a
  positive integer — the same guard `arm_idle/1` uses, so `0` means disabled to
  both. Where the drain is off, nothing can be LRU-evicted either.

  That is now the explicit opt-out case only: the drain defaults ON
  (`CrdtCheckpointTimer.@default_idle_exit_ms`), so in prod every note room is
  enrolled and this table is live. It previously read "prod today, where nothing
  sets idle_exit_ms" — that was the bug, not the design. CI/e2e additionally
  overrides the window via `CRDT_IDLE_EXIT_MS` (`ci/compose.yml`) so the Obsidian
  suite exercises this against the real client at an observable timescale.

  And the unblocking event is **#1151, not #1150**: #1150's index room resolves
  its own `idle_exit_ms` before reaching the timer, so it is unaffected by this
  module's default either way.

  `touch/3` and `forget/1` no-op while the table is missing. The table is owned
  by this module's GenServer, so a bare `:ets` call would raise in the CALLER —
  a `CrdtCheckpointTimer` that is linked to a room which does not trap exits.
  The room would die by signal, skipping `terminate/2` and its unbind
  checkpoint. A memory backstop must never cost a room its checkpoint.

  Every tracked pid is LOCAL: a room's timer is started on the same node as the
  room (`CrdtDoc.start_link`), so `Process.alive?/1` — which raises on remote
  pids — is safe here. Each node bounds its own residency, which is correct
  because memory is per-node.

  ## Config

      config :engram, Engram.Notes.CrdtRoomLru,
        max_resident: 64,  # the default; see @default_max_resident
        sweep_interval_ms: 30_000

  `max_resident` wants tuning against real index-doc sizes once #1150 exists —
  #1146's arithmetic says ~128 resident rooms would consume an entire task, so
  the default deliberately sits well under that.
  """
  use GenServer

  alias Engram.Logger.Metadata
  alias Engram.Notes.CrdtRegistry

  require Logger

  @table :crdt_room_lru
  # Ceiling on resident rooms per node, enforced regardless of idleness so a bulk
  # upload cannot outrun the idle timer.
  #
  # Do NOT raise this on note-room arithmetic alone. A 2026-08-18 measurement put
  # note rooms at ~162 KB, which makes 256 look like a comfortable ~41 MB — but
  # this table is COUNT-based and also tracks index rooms, which the moduledoc
  # measures at ~7.91 MB per 10k-note vault, roughly 50x a note room. A node
  # holding mostly index rooms would sit well under a count-based cap while
  # blowing the memory budget the cap exists to defend, so the binding constraint
  # is #1146's ~128-rooms-consumes-a-task figure, not the note-room average.
  @default_max_resident 64
  @default_sweep_interval_ms 30_000

  # Most rooms a single sweep may evict.
  #
  # An eviction sends one `{:crdt_room_drain, pid}` to the owning channel, and a
  # channel handles them SERIALLY out of its mailbox — each costing a
  # `room_responsive?` probe bounded at `crdt_channel.@room_probe_ms` (1s) plus
  # an unobserve. Unpaced, a node far over cap hands one socket a queue of
  # drains: instant when rooms are healthy, but minutes of head-of-line blocking
  # exactly when they are not (a starved pool — see #1411), which stalls the
  # client's own frames behind it.
  #
  # Unlike the idle path this has no jitter, so the burst lands all at once.
  # Capping the batch bounds the worst case to `cap x probe` per sweep and lets a
  # backlog drain down over successive sweeps instead.
  #
  # Consequence to know: while a bulk upload creates rooms faster than this
  # reclaims them, residency exceeds `max_resident` between sweeps. That is the
  # accepted trade — a lagging bound beats a wedged socket — and it stops
  # mattering once a bulk upload no longer creates a room per note (#1409).
  @max_evictions_per_sweep 16
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
    with_table(fn tid ->
      :ets.insert(tid, {note_id, room_pid, vault_id, System.monotonic_time(:millisecond)})
    end)
  end

  @doc "Drop a room's entry (its room exited)."
  @spec forget(String.t()) :: :ok
  def forget(note_id), do: with_table(fn tid -> :ets.delete(tid, note_id) end)

  @doc """
  Rooms tracked on this node, INCLUDING any that exited since the last sweep —
  `prune_dead/0` only runs on a sweep. Call `sweep/1` first if you need a live
  count. Returns 0 while the owning process is restarting.
  """
  @spec resident_count() :: non_neg_integer()
  def resident_count do
    case :ets.whereis(@table) do
      :undefined -> 0
      tid -> :ets.info(tid, :size)
    end
  end

  # This module's GenServer owns the table, so between its death and its
  # restart the table does not exist. A bare :ets call would raise
  # ArgumentError in the CALLER — and the caller is CrdtCheckpointTimer, which
  # links itself to its room and is started by a hard match in
  # CrdtDoc.start_link. The room does not trap exits, so it would die by signal,
  # skipping terminate/2 and therefore skipping CrdtPersistence.unbind/3's
  # checkpoint. The LRU is a memory backstop; it must never be able to cost a
  # room its checkpoint. Degrade instead: a missed touch costs one sweep's worth
  # of ordering accuracy.
  defp with_table(fun) do
    case :ets.whereis(@table) do
      :undefined -> :ok
      tid -> _ = fun.(tid)
    end

    :ok
  end

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
      |> Enum.take(min(excess, @max_evictions_per_sweep))
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
    # `backlog` is what this sweep is deliberately NOT evicting because of
    # @max_evictions_per_sweep. Logged explicitly so a paced sweep can never read
    # as "residency is under control" when it is only catching up.
    backlog = max(resident - cap - length(note_ids), 0)

    Logger.warning(
      "crdt room LRU evicting #{length(note_ids)} room(s) — resident=#{resident} cap=#{cap} backlog=#{backlog}",
      Engram.Logger.Metadata.with_category(:warning, :sync)
    )

    for note_id <- note_ids do
      case :ets.lookup(@table, note_id) do
        [{^note_id, pid, vault_id, _last}] ->
          ask_to_drain(note_id, pid, vault_id)

        [] ->
          :ok
      end
    end

    :ok
  end

  # Same broadcast the idle timer sends: observers let go, auto_exit
  # checkpoints. Counted under its own phase so a dashboard can tell
  # memory-pressure eviction from an ordinary idle drain.
  defp ask_to_drain(note_id, pid, vault_id) do
    case Phoenix.PubSub.broadcast(
           Engram.PubSub,
           CrdtRegistry.drain_topic(vault_id),
           {:crdt_room_drain, pid}
         ) do
      :ok ->
        # Re-stamp as "asked just now". An ask is not an exit: if no observer
        # acts, the room keeps its old timestamp, stays the oldest entry, and is
        # re-selected on EVERY later sweep — monopolising the eviction slate
        # while residency never comes down, and inflating this counter with
        # repeat asks for one stuck room. Moving it to the back of the queue
        # gives the other rooms a turn; if the drain does work, the room exits
        # and `forget/1` removes the entry anyway.
        _ = :ets.update_element(@table, note_id, {4, System.monotonic_time(:millisecond)})
        :telemetry.execute(@drain_event, %{count: 1}, %{phase: :lru_evicted})

      {:error, reason} ->
        # Do NOT count this as an eviction: nothing was asked, so the room is
        # still resident. Counting it would make the capacity signal read as
        # "we are shedding load" during precisely the failure where we are not.
        Logger.warning(
          "crdt room LRU drain broadcast failed for #{note_id}: #{Metadata.safe_reason(reason)}",
          Engram.Logger.Metadata.with_category(:warning, :sync)
        )
    end
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, sweep_interval_ms())

  defp cfg, do: Application.get_env(:engram, __MODULE__, [])
  defp max_resident, do: Keyword.get(cfg(), :max_resident) || @default_max_resident
  defp sweep_interval_ms, do: Keyword.get(cfg(), :sweep_interval_ms) || @default_sweep_interval_ms
end
