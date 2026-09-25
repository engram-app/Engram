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
        sweep_interval_ms: 30_000,
        over_cap_sweep_ms: 1_000,  # a new room past the cap sweeps this soon
        drain_grace_ms: 5_000      # an asked room still alive after this = stuck

  ## Who gets evicted (#1412)

  Not the oldest rooms on the node — the oldest rooms of the vault holding the
  MOST rooms. A bulk sync by one user sheds its own rooms before it can touch
  a room another user is typing in; see `select_evictions/3`.

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

  # Most rooms a sweep may evict WHILE DRAINS ARE NOT LANDING. Healthy sweeps
  # evict the whole excess.
  #
  # An eviction sends one `{:crdt_room_drain, pid}` to the owning channel, and a
  # channel handles them SERIALLY out of its mailbox — each costing a
  # `room_responsive?` probe bounded at `crdt_channel.@room_probe_ms` (1s) plus
  # an unobserve. On healthy rooms that is milliseconds per drain. On wedged ones
  # (a starved pool — see #1411) it is up to 1s each, and an unpaced sweep would
  # stall the owning socket's frames for minutes.
  #
  # This used to be applied to EVERY sweep. On 2026-09-14 that let one import
  # hold 1,175 rooms against a cap of 64 for ten minutes, to guard against a
  # wedge that was not happening. So the pace is now conditional: a room still
  # resident `drain_grace_ms` after it was asked is the wedge signal, and only
  # then does a sweep fall back to this limit.
  @paced_evictions_per_sweep 16
  @default_over_cap_sweep_ms 1_000
  @default_drain_grace_ms 5_000
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
      entry = {note_id, room_pid, vault_id, System.monotonic_time(:millisecond)}

      # Only a NEW entry grows residency, so only it checks the cap — a write to
      # a resident room stays a bare insert. Cast, not send: a cast to a name
      # that is mid-restart is dropped instead of raising in the caller (see
      # `with_table/1` for why the caller must never raise).
      if :ets.insert_new(tid, entry) do
        if :ets.info(tid, :size) > max_resident(), do: GenServer.cast(__MODULE__, :over_cap)
      else
        :ets.insert(tid, entry)
      end
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

  @doc """
  The resident-room ceiling this node is enforcing right now.

  Public because `resident_count/0` is meaningless on its own: the number that
  matters is the OVERSHOOT, and a dashboard or alert that hardcodes 64 starts
  lying the day `config :engram, #{inspect(__MODULE__)}, max_resident:` moves.
  Exported next to the count so both travel together — see
  `Engram.PromEx.Crdt.execute_room_metrics/0`.
  """
  @spec max_resident() :: pos_integer()
  def max_resident, do: Keyword.get(cfg(), :max_resident) || @default_max_resident

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
  Which note_ids to evict: `length(entries) - cap` of them (at most `limit`),
  taken from the vault holding the most rooms first, least recently active
  first within a vault. Pure, so the policy is testable without rooms or ETS.

  Each room is ranked by its DEPTH in its own vault — the vault's newest room is
  depth 1, its oldest is depth N. Evicting deepest-first levels the largest
  vaults down together, so a vault is only touched once it holds as many rooms
  as the biggest one left. Ties go to the older room.
  """
  @spec select_evictions(
          [{String.t(), pid(), String.t(), integer()}],
          non_neg_integer(),
          pos_integer() | :infinity
        ) :: [String.t()]
  def select_evictions(entries, cap, limit \\ :infinity) do
    excess = length(entries) - cap

    if excess <= 0 do
      []
    else
      entries
      |> Enum.group_by(fn {_id, _pid, vault, _last} -> vault end)
      |> Enum.flat_map(fn {_vault, rooms} ->
        rooms
        |> Enum.sort_by(fn {_id, _pid, _vault, last} -> last end, :desc)
        |> Enum.with_index(1)
      end)
      |> Enum.sort_by(fn {{_id, _pid, _vault, last}, depth} -> {-depth, last} end)
      # Integer < atom in term order, so `min(n, :infinity)` is `n`.
      |> Enum.take(min(excess, limit))
      |> Enum.map(fn {{id, _pid, _vault, _last}, _depth} -> id end)
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
    {:ok, initial_state()}
  end

  # `asked`: note_id => {pid, first_asked_at} for drains not yet seen to land.
  # `over_cap_timer`: a prompt sweep is already scheduled, so a burst of new
  # rooms coalesces into one sweep instead of one per room.
  # `paced`: the last sweep found stuck drains. Prompt sweeps stand down until a
  # sweep finds none, so a wedge gets at most one paced batch per interval.
  defp initial_state, do: %{asked: %{}, over_cap_timer: nil, paced: false}

  @impl true
  def handle_call({:sweep, cap}, _from, state) do
    {:reply, :ok, do_sweep(cap || max_resident(), state)}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    _ = cancel_over_cap_timer(state)
    {:reply, :ok, initial_state()}
  end

  @impl true
  def handle_cast(:over_cap, %{over_cap_timer: ref} = state) when ref != nil,
    do: {:noreply, state}

  # While drains are stuck every drain can cost its channel a 1s probe, and
  # prompt sweeps would queue a paced batch per second instead of per interval.
  def handle_cast(:over_cap, %{paced: true} = state), do: {:noreply, state}

  def handle_cast(:over_cap, state) do
    ref = Process.send_after(self(), :over_cap_sweep, over_cap_sweep_ms())
    {:noreply, %{state | over_cap_timer: ref}}
  end

  @impl true
  def handle_info(:sweep, state) do
    state = do_sweep(max_resident(), state)
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(:over_cap_sweep, state) do
    {:noreply, do_sweep(max_resident(), %{state | over_cap_timer: nil})}
  end

  # Private ------------------------------------------------------------------

  defp do_sweep(cap, state) do
    live = prune_dead()
    now = System.monotonic_time(:millisecond)
    live_keys = MapSet.new(live, fn {id, pid, _vault, _last} -> {id, pid} end)

    # Drains still outstanding: same note, same room pid, still resident. A
    # replacement room for the note (new pid) means the old drain landed.
    outstanding = Map.filter(state.asked, fn {id, {pid, _at}} -> {id, pid} in live_keys end)
    grace = drain_grace_ms()
    {stuck, exiting} = Map.split_with(outstanding, fn {_id, {_pid, at}} -> now - at >= grace end)
    stuck? = map_size(stuck) > 0
    limit = if stuck?, do: @paced_evictions_per_sweep, else: :infinity

    # A room asked inside the grace window is on its way out (its checkpoint
    # takes a moment). It is neither a candidate nor part of the excess: counting
    # it would re-ask it, and since an ask restamps a room as newest, a quick
    # second sweep would then drain the very rooms the first one kept.
    candidates =
      Enum.reject(live, fn {id, pid, _vault, _last} ->
        match?({^pid, _}, Map.get(exiting, id))
      end)

    evictions = select_evictions(candidates, cap, limit)
    backlog = max(length(candidates) - cap - length(evictions), 0)
    asked = evict(evictions, cap, length(live), backlog, stuck?)

    # Pacing also stands down any prompt sweep armed before the wedge showed.
    state = if stuck?, do: cancel_over_cap_timer(state), else: state

    # The FIRST ask time wins: re-asking a stuck room every sweep must not keep
    # restarting its grace clock.
    %{
      state
      | asked: Map.merge(Map.new(asked, &{elem(&1, 0), {elem(&1, 1), now}}), outstanding),
        paced: stuck?
    }
  end

  defp cancel_over_cap_timer(%{over_cap_timer: nil} = state), do: state

  defp cancel_over_cap_timer(state) do
    _ = Process.cancel_timer(state.over_cap_timer)
    %{state | over_cap_timer: nil}
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

  defp evict([], _cap, _resident, _backlog, _paced?), do: []

  # Returns `[{note_id, pid}]` for every room actually asked to drain.
  #
  # Never silent: an LRU eviction means the idle drain alone was not keeping up,
  # which is a capacity signal and not routine. `backlog` is what this sweep is
  # deliberately NOT evicting because earlier drains have not landed
  # (`paced=true`). Logged explicitly so a paced sweep can never read as
  # "residency is under control" when it is only catching up.
  defp evict(note_ids, cap, resident, backlog, paced?) do
    Logger.warning(
      "crdt room LRU evicting #{length(note_ids)} room(s) — resident=#{resident} cap=#{cap} backlog=#{backlog} paced=#{paced?}",
      Engram.Logger.Metadata.with_category(:warning, :sync)
    )

    for note_id <- note_ids,
        [{^note_id, pid, vault_id, _last}] <- [:ets.lookup(@table, note_id)],
        ask_to_drain(note_id, pid, vault_id) == :ok,
        do: {note_id, pid}
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
        :ok

      {:error, reason} ->
        # Do NOT count this as an eviction: nothing was asked, so the room is
        # still resident. Counting it would make the capacity signal read as
        # "we are shedding load" during precisely the failure where we are not.
        Logger.warning(
          "crdt room LRU drain broadcast failed for #{note_id}: #{Metadata.safe_reason(reason)}",
          Engram.Logger.Metadata.with_category(:warning, :sync)
        )

        :error
    end
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, sweep_interval_ms())

  defp cfg, do: Application.get_env(:engram, __MODULE__, [])
  defp sweep_interval_ms, do: Keyword.get(cfg(), :sweep_interval_ms) || @default_sweep_interval_ms
  defp over_cap_sweep_ms, do: Keyword.get(cfg(), :over_cap_sweep_ms) || @default_over_cap_sweep_ms
  defp drain_grace_ms, do: Keyword.get(cfg(), :drain_grace_ms) || @default_drain_grace_ms
end
