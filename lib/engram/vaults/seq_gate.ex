defmodule Engram.Vaults.SeqGate do
  @moduledoc """
  Per-vault in-BEAM mutex taken BEFORE a write opens its DB transaction.

  `Vaults.next_seq!/2` row-locks the vault, so writes to one vault run one at a
  time. Without this gate each waiter sits on a checked-out pool connection
  while it waits: ~10 concurrent writes to one vault (a client deleting 400
  attachments one by one) empty a 10-connection pool and every unrelated
  request dies with `dropped from queue`. Here the waiters queue in this
  process instead and hold no connection.

  Wrap only a short transaction (`with_tenant/4`, or `with_vault/3` around a
  `Repo.transaction`). Slow work (KMS/HMAC, S3, CRDT merge, encryption) stays
  outside, or it serializes per vault.

  ## Behaviour

    * Partitioned: a `PartitionSupervisor` of gate processes, keyed by vault.
      A crash affects only that partition's vaults.
    * Holder death releases the lock (monitored), so a crash cannot leak it.
    * FAILS CLOSED. A wait timeout, or a gate that stays down past the wait
      budget, raises `BusyError` (HTTP 429 + `retry-after`, which the plugin
      honors). A crashed partition is retried until the budget runs out:
      running its waiters ungated all at once is the incident shape.
    * A call already inside a DB transaction skips the gate: it holds a
      connection and possibly the row lock, so waiting here could deadlock
      against the holder. A nested call for the same vault in the same process
      just runs (per process; a Task spawned inside the gate is NOT the holder).

  ## Telemetry (`Engram.PromEx.SeqGate`)

    * `[:engram, :seq_gate, :acquire]` `%{duration}` (wait), `%{result: :ok | :busy}`
    * `[:engram, :seq_gate, :hold]` `%{duration}` (time holding the gate)
    * `[:engram, :seq_gate, :queue]` `%{held, waiting}`, polled per node

  ## Limits

    * Per node: with N web nodes a vault can have N writers inside the DB, so a
      vault's pool use is capped at N connections, not the pool size.
    * After a partition restarts, holders that were inside the DB still finish
      while the new process grants new callers: briefly two writers per vault
      for that partition. The DB row lock keeps this correct.
    * Gated: REST attachment upsert (`commit_row`), delete and move; REST note
      delete and rename; every MCP tool call that writes vault data (taken in
      `McpController` before its request transaction opens), and MCP tools
      outside the request transaction that reach those (`rename_note`); an MCP
      shed answers a `rate_limited` tool error. The channel `crdt_delete`, on
      the shorter `channel_wait_ms/0` budget and off the channel process,
      replying `busy`. NOT gated: REST note upsert (its transaction runs the
      CRDT merge), batch and folder ops (one lock per transaction), the other
      CRDT channel writes and checkpoints, and Oban workers other than the
      vault index projection.
  """
  use GenServer

  alias Engram.Repo

  require Logger

  defmodule BusyError do
    @moduledoc """
    The vault's write queue did not drain within the wait budget. A 429, not a
    5xx: it is load, so it stays out of Sentry, and the plugin retries a 429
    after `retry-after` instead of parking the write (`EngramWeb.Plugs.RetryAfter`
    supplies the header).
    """
    defexception message: "vault write queue saturated, retry", plug_status: 429
  end

  # The wait budget lives in config (`:seq_gate_wait_ms`, config/config.exs),
  # with the constraint it must respect documented there.
  # Pause between retries while a crashed partition restarts.
  @restart_backoff_ms 10

  def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, Keyword.take(opts, [:name]))

  @doc "`Repo.with_tenant/2` run while holding the vault's gate."
  def with_tenant(user_id, vault_id, fun, opts \\ []),
    do: with_vault(vault_id, fn -> Repo.with_tenant(user_id, fun) end, opts)

  @doc """
  Run `fun` holding the vault's gate. Options: `:gate` (the PartitionSupervisor
  name, for tests), `:timeout` (wait budget in ms).
  """
  def with_vault(vault_id, fun, opts \\ []) do
    key = {:seq_gate, vault_id}

    if Process.get(key) || Repo.in_transaction?() do
      fun.()
    else
      gate = Keyword.get(opts, :gate, __MODULE__)
      timeout = Keyword.get_lazy(opts, :timeout, &wait_ms/0)
      started = System.monotonic_time()
      result = acquire(gate, vault_id, started + ms_to_native(timeout))
      now = System.monotonic_time()

      :telemetry.execute([:engram, :seq_gate, :acquire], %{duration: now - started}, %{
        result: result
      })

      if result == :busy do
        Logger.warning("vault seq gate saturated, shedding write", category: :sync)
        raise BusyError
      end

      Process.put(key, true)

      try do
        fun.()
      after
        Process.delete(key)

        :telemetry.execute(
          [:engram, :seq_gate, :hold],
          %{duration: System.monotonic_time() - now},
          %{}
        )

        cast(gate, vault_id, {:release, vault_id, self()})
      end
    end
  end

  @doc "Longest a write queues for its vault's gate before shedding with `BusyError`."
  def wait_ms, do: Application.fetch_env!(:engram, :seq_gate_wait_ms)

  @doc "`wait_ms/0` for a write that arrived over a channel (see config/config.exs)."
  def channel_wait_ms, do: Application.fetch_env!(:engram, :seq_gate_channel_wait_ms)

  @doc """
  Whether the vault's gate has writers queued behind its holder on this node.
  Cheap (one call to the vault's partition); `false` when the gate is down.
  For callers that would otherwise do expensive work only to queue and shed.
  """
  def contended?(vault_id, gate \\ __MODULE__) do
    GenServer.call(via(gate, vault_id), {:contended?, vault_id}, 1_000)
  catch
    :exit, _ -> false
  end

  @doc "Held and queued writes across this node's partitions."
  def queue_depth(gate \\ __MODULE__) do
    gate
    |> PartitionSupervisor.which_children()
    |> Enum.reduce(%{held: 0, waiting: 0}, fn {_, pid, _, _}, acc ->
      try do
        %{held: h, waiting: w} = GenServer.call(pid, :depth, 1_000)
        %{held: acc.held + h, waiting: acc.waiting + w}
      catch
        :exit, _ -> acc
      end
    end)
  end

  defp acquire(gate, vault_id, deadline) do
    remaining = native_to_ms(deadline - System.monotonic_time())

    if remaining <= 0 do
      :busy
    else
      try do
        GenServer.call(via(gate, vault_id), {:acquire, vault_id}, remaining)
      catch
        :exit, reason ->
          # Withdraw first: a timed-out waiter still in the queue would be
          # granted the lock and hold it until it dies.
          cast(gate, vault_id, {:cancel, vault_id, self()})

          case reason do
            {:timeout, _} ->
              :busy

            _crashed_or_restarting ->
              Process.sleep(min(@restart_backoff_ms, remaining))
              acquire(gate, vault_id, deadline)
          end
      end
    end
  end

  # Cast, so a dead gate (or a missing supervisor) cannot hang or crash us.
  defp cast(gate, vault_id, msg) do
    GenServer.cast(via(gate, vault_id), msg)
  catch
    :exit, _ -> :ok
  end

  defp via(gate, vault_id), do: {:via, PartitionSupervisor, {gate, vault_id}}

  defp ms_to_native(ms), do: System.convert_time_unit(ms, :millisecond, :native)
  defp native_to_ms(n), do: System.convert_time_unit(n, :native, :millisecond)

  # State per partition: `locks` maps vault_id to
  # `%{holder, ref, queue, waiters}`. `queue` keeps arrival order (pids);
  # `waiters` (pid => {from, monitor_ref}) is the live set. A cancelled or dead
  # waiter is removed from `waiters` only (O(1)); `pump` skips queue entries
  # with no live waiter, so neither cancel nor death scans the queue. `refs`
  # maps every monitor to `vault_id` (holder) or `{:waiter, vault_id, pid}`.
  @impl true
  def init(:ok), do: {:ok, %{locks: %{}, refs: %{}}}

  @impl true
  def handle_call({:acquire, vault_id}, {pid, _} = from, state) do
    case state.locks do
      %{^vault_id => lock} -> {:noreply, enqueue(state, vault_id, lock, pid, from)}
      _ -> {:reply, :ok, grant(state, vault_id, pid, :queue.new(), %{})}
    end
  end

  def handle_call({:contended?, vault_id}, _from, state) do
    contended =
      case state.locks do
        %{^vault_id => %{waiters: w}} -> map_size(w) > 0
        _ -> false
      end

    {:reply, contended, state}
  end

  def handle_call(:depth, _from, state) do
    waiting = state.locks |> Map.values() |> Enum.map(&map_size(&1.waiters)) |> Enum.sum()
    {:reply, %{held: map_size(state.locks), waiting: waiting}, state}
  end

  @impl true
  def handle_cast({:release, vault_id, pid}, state), do: {:noreply, release(state, vault_id, pid)}

  def handle_cast({:cancel, vault_id, pid}, state) do
    {:noreply, state |> drop_waiter(vault_id, pid) |> release(vault_id, pid)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    case state.refs do
      %{^ref => {:waiter, vault_id, ^pid}} -> {:noreply, drop_waiter(state, vault_id, pid)}
      %{^ref => vault_id} -> {:noreply, release(state, vault_id, pid)}
      _ -> {:noreply, state}
    end
  end

  # A pid already waiting (a stale entry from a timed-out call) keeps its place
  # and monitor; the reply goes to its newest `from`.
  defp enqueue(state, vault_id, lock, pid, from) do
    {lock, refs} =
      case lock.waiters do
        %{^pid => {_old, mref}} ->
          {%{lock | waiters: Map.put(lock.waiters, pid, {from, mref})}, state.refs}

        _ ->
          mref = Process.monitor(pid)

          {%{
             lock
             | queue: :queue.in(pid, lock.queue),
               waiters: Map.put(lock.waiters, pid, {from, mref})
           }, Map.put(state.refs, mref, {:waiter, vault_id, pid})}
      end

    %{state | locks: Map.put(state.locks, vault_id, lock), refs: refs}
  end

  defp drop_waiter(state, vault_id, pid) do
    with %{^vault_id => lock} <- state.locks,
         {{_from, mref}, waiters} <- Map.pop(lock.waiters, pid) do
      Process.demonitor(mref, [:flush])

      %{
        state
        | locks: Map.put(state.locks, vault_id, %{lock | waiters: waiters}),
          refs: Map.delete(state.refs, mref)
      }
    else
      _ -> state
    end
  end

  defp grant(state, vault_id, pid, queue, waiters) do
    ref = Process.monitor(pid)
    lock = %{holder: pid, ref: ref, queue: queue, waiters: waiters}

    %{
      state
      | locks: Map.put(state.locks, vault_id, lock),
        refs: Map.put(state.refs, ref, vault_id)
    }
  end

  # Only the current holder can release; a stale cast is ignored.
  defp release(state, vault_id, pid) do
    case state.locks do
      %{^vault_id => %{holder: ^pid, ref: ref} = lock} ->
        Process.demonitor(ref, [:flush])

        state = %{
          state
          | locks: Map.delete(state.locks, vault_id),
            refs: Map.delete(state.refs, ref)
        }

        pump(state, vault_id, lock.queue, lock.waiters)

      _ ->
        state
    end
  end

  # Hand the lock to the next live waiter, skipping cancelled or dead entries.
  defp pump(state, vault_id, queue, waiters) do
    case :queue.out(queue) do
      {:empty, _} ->
        state

      {{:value, pid}, rest} ->
        case Map.pop(waiters, pid) do
          {nil, _} ->
            pump(state, vault_id, rest, waiters)

          {{from, mref}, waiters} ->
            Process.demonitor(mref, [:flush])
            state = %{state | refs: Map.delete(state.refs, mref)}

            if Process.alive?(pid) do
              GenServer.reply(from, :ok)
              grant(state, vault_id, pid, rest, waiters)
            else
              pump(state, vault_id, rest, waiters)
            end
        end
    end
  end
end
