defmodule Engram.Vaults.SeqGate do
  @moduledoc """
  Per-vault in-BEAM mutex taken BEFORE a write opens its DB transaction.

  `Vaults.next_seq!/2` row-locks the vault, so single writes to one vault run
  one at a time. Without this gate each waiter sits on a checked-out pool
  connection while it waits: ~10 concurrent writes to one vault (a client
  deleting 400 attachments one by one) empty a 10-connection pool and every
  unrelated request dies with `dropped from queue`. Here the waiters queue in
  this process instead and hold no connection.

  The DB row lock stays the correctness boundary. This gate only decides who
  queues where, so it degrades open: on wait timeout or a missing gate the work
  runs anyway.

  Limits: per node. With N web nodes a vault can still have N writers inside the
  DB, so pool use is capped at N connections for that vault instead of the
  pool size. Not re-entrant across processes; within a process a nested call for
  the same vault just runs, and a call already inside a DB transaction skips the
  gate (it holds a connection and possibly the row lock, so waiting here could
  deadlock against the holder).

  A holder that dies is demonitored-released, so a crash cannot leak a lock.

  ## Per-user write bulkhead

  The same process also counts in-flight writes per USER (`enter_user/2`,
  `leave_user/1`, used by `EngramWeb.Plugs.WriteConcurrency`). Request-count
  limiters never see a burst that stays under N/minute but all lands at once;
  this caps how many pool connections one user can occupy (default: half the
  pool, `:write_inflight_cap` overrides). Entries are monitored, so a crashed
  request process frees its slot. Per node, like the lock: a user spread over N
  nodes can hold N x cap.
  """
  use GenServer
  require Logger

  # Longest a queued write waits. A single seq-bumping write is milliseconds, so
  # this is only hit under real saturation, then the write runs ungated.
  @default_timeout 15_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, name: opts[:name] || __MODULE__)

  @doc "Run `fun` holding the vault's gate. Options: `:gate`, `:timeout`."
  def with_vault(vault_id, fun, opts \\ []) do
    key = {:seq_gate, vault_id}

    if Process.get(key) || Engram.Repo.in_transaction?() do
      fun.()
    else
      gate = Keyword.get(opts, :gate, __MODULE__)

      case acquire(gate, vault_id, Keyword.get(opts, :timeout, @default_timeout)) do
        :ok ->
          Process.put(key, true)

          try do
            fun.()
          after
            Process.delete(key)
            GenServer.cast(gate, {:release, vault_id, self()})
          end

        :degraded ->
          fun.()
      end
    end
  end

  @doc "Max concurrent writes per user on this node (half the DB pool, min 2)."
  def user_cap do
    case Application.get_env(:engram, :write_inflight_cap) do
      n when is_integer(n) and n > 0 ->
        n

      _ ->
        pool = Keyword.get(Application.get_env(:engram, Engram.Repo, []), :pool_size, 10)
        max(2, div(pool, 2))
    end
  end

  @doc """
  Take a per-user in-flight write slot for the calling process: `{:ok, ref}` or
  `:deny` when the user is at `cap`. Degrades open (`{:ok, nil}`) if the gate is
  down. Free it with `leave_user/1`; the caller's death frees it too.
  """
  def enter_user(user_id, cap \\ user_cap(), gate \\ __MODULE__) do
    GenServer.call(gate, {:enter_user, user_id, cap}, 1_000)
  catch
    :exit, _ -> {:ok, nil}
  end

  def leave_user(ref, gate \\ __MODULE__)
  def leave_user(nil, _gate), do: :ok
  def leave_user(ref, gate), do: GenServer.cast(gate, {:leave_user, ref})

  defp acquire(gate, vault_id, timeout) do
    GenServer.call(gate, {:acquire, vault_id}, timeout)
  catch
    :exit, _ ->
      # Withdraw first: a timed-out waiter still in the queue would be granted
      # the lock and never release it. Cast, so a dead gate cannot hang us.
      try do
        GenServer.cast(gate, {:cancel, vault_id, self()})
      catch
        :exit, _ -> :ok
      end

      Logger.warning("vault seq gate unavailable or saturated, writing ungated", category: :sync)
      :degraded
  end

  @impl true
  def init(:ok), do: {:ok, %{locks: %{}, refs: %{}, inflight: %{}, counts: %{}}}

  @impl true
  def handle_call({:acquire, vault_id}, {pid, _} = from, state) do
    case state.locks do
      %{^vault_id => lock} ->
        lock = %{lock | waiting: :queue.in(from, lock.waiting)}
        {:noreply, put_in(state.locks[vault_id], lock)}

      _ ->
        {:reply, :ok, grant(state, vault_id, pid, :queue.new())}
    end
  end

  def handle_call({:enter_user, user_id, cap}, {pid, _}, state) do
    if Map.get(state.counts, user_id, 0) >= cap do
      {:reply, :deny, state}
    else
      ref = Process.monitor(pid)

      state = %{
        state
        | inflight: Map.put(state.inflight, ref, user_id),
          counts: Map.update(state.counts, user_id, 1, &(&1 + 1))
      }

      {:reply, {:ok, ref}, state}
    end
  end

  @impl true
  def handle_cast({:leave_user, ref}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, leave(state, ref)}
  end

  def handle_cast({:release, vault_id, pid}, state), do: {:noreply, release(state, vault_id, pid)}

  def handle_cast({:cancel, vault_id, pid}, state) do
    state =
      case state.locks do
        %{^vault_id => lock} ->
          waiting = :queue.filter(fn {w, _} -> w != pid end, lock.waiting)
          put_in(state.locks[vault_id], %{lock | waiting: waiting})

        _ ->
          state
      end

    {:noreply, release(state, vault_id, pid)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    case state.refs do
      %{^ref => vault_id} -> {:noreply, release(state, vault_id, pid)}
      _ -> {:noreply, leave(state, ref)}
    end
  end

  defp leave(state, ref) do
    case Map.pop(state.inflight, ref) do
      {nil, _} ->
        state

      {user_id, inflight} ->
        counts =
          case Map.fetch!(state.counts, user_id) do
            1 -> Map.delete(state.counts, user_id)
            n -> Map.put(state.counts, user_id, n - 1)
          end

        %{state | inflight: inflight, counts: counts}
    end
  end

  defp grant(state, vault_id, pid, waiting) do
    ref = Process.monitor(pid)
    lock = %{holder: pid, ref: ref, waiting: waiting}

    %{
      state
      | locks: Map.put(state.locks, vault_id, lock),
        refs: Map.put(state.refs, ref, vault_id)
    }
  end

  # Only the current holder can release; a stale cast is ignored.
  defp release(state, vault_id, pid) do
    case state.locks do
      %{^vault_id => %{holder: ^pid, ref: ref, waiting: waiting}} ->
        Process.demonitor(ref, [:flush])

        state = %{
          state
          | locks: Map.delete(state.locks, vault_id),
            refs: Map.delete(state.refs, ref)
        }

        pump(state, vault_id, waiting)

      _ ->
        state
    end
  end

  # Hand the lock to the next live waiter; skip ones that died while queued.
  defp pump(state, vault_id, waiting) do
    case :queue.out(waiting) do
      {:empty, _} ->
        state

      {{:value, {pid, _} = from}, rest} ->
        if Process.alive?(pid) do
          GenServer.reply(from, :ok)
          grant(state, vault_id, pid, rest)
        else
          pump(state, vault_id, rest)
        end
    end
  end
end
