defmodule Engram.Vaults.SeqGate do
  @moduledoc """
  Per-vault in-BEAM mutex taken BEFORE a write opens its DB transaction.

  `Vaults.next_seq!/2` row-locks the vault, so writes to one vault run one at a
  time. Without this gate each waiter sits on a checked-out pool connection
  while it waits: ~10 concurrent writes to one vault (a client deleting 400
  attachments one by one) empty a 10-connection pool and every unrelated
  request dies with `dropped from queue`. Here the waiters queue in this
  process instead and hold no connection.

  Wrap the transaction itself (`with_tenant/3`, or `with_vault/2` around a
  `Repo.transaction`), not the whole request: keep KMS/S3 work outside so it
  does not serialize per vault.

  ## Behaviour

    * Holder death releases the lock (monitored), so a crash cannot leak it.
    * Wait timeout SHEDS: raises `Busy` (HTTP 503). Running ungated would put
      every late waiter back on a pool connection, recreating the incident
      exactly when the gate matters.
    * Gate not running (or crashed mid-wait): runs ungated. The DB row lock is
      the correctness boundary; this gate only decides who waits where.
    * A call already inside a DB transaction skips the gate: it holds a
      connection and possibly the row lock, so waiting here could deadlock
      against the holder. A nested call for the same vault in the same process
      just runs (per-process; a Task spawned inside the gate is NOT the holder).

  ## Limits

    * Per node: with N web nodes a vault can have N writers inside the DB, so a
      vault's pool use is capped at N connections, not the pool size.
    * One process for all vaults. Messages are tiny and the state is a map
      keyed by vault, so this is far from a bottleneck at current load; a crash
      drops the queue and waiters run ungated (see above).
    * Gated writers: attachment upsert/delete/move, note upsert/delete/rename.
      Batch and folder ops take the lock once per transaction and are not gated
      yet, nor are CRDT checkpoints and Oban workers.
  """
  use GenServer

  alias Engram.Repo

  require Logger

  defmodule Busy do
    @moduledoc "The vault's write queue did not drain within the wait budget."
    defexception message: "vault write queue saturated, retry", plug_status: 503
  end

  # Longest a queued write waits. A single seq-bumping write is milliseconds, so
  # this is only hit under real saturation, and then we shed.
  @default_timeout 15_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, name: opts[:name] || __MODULE__)

  @doc "`Repo.with_tenant/2` run while holding the vault's gate."
  def with_tenant(user_id, vault_id, fun, opts \\ []),
    do: with_vault(vault_id, fn -> Repo.with_tenant(user_id, fun) end, opts)

  @doc "Run `fun` holding the vault's gate. Options: `:gate`, `:timeout`."
  def with_vault(vault_id, fun, opts \\ []) do
    key = {:seq_gate, vault_id}

    if Process.get(key) || Repo.in_transaction?() do
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

        :ungated ->
          fun.()
      end
    end
  end

  defp acquire(gate, vault_id, timeout) do
    GenServer.call(gate, {:acquire, vault_id}, timeout)
  catch
    :exit, reason ->
      # Withdraw first: a timed-out waiter still in the queue would be granted
      # the lock and hold it until it dies. Cast, so a dead gate cannot hang us.
      try do
        GenServer.cast(gate, {:cancel, vault_id, self()})
      catch
        :exit, _ -> :ok
      end

      case reason do
        {:timeout, _} ->
          Logger.warning("vault seq gate saturated, shedding write", category: :sync)
          raise Busy

        _ ->
          Logger.warning("vault seq gate unavailable, writing ungated", category: :sync)
          :ungated
      end
  end

  @impl true
  def init(:ok), do: {:ok, %{locks: %{}, refs: %{}}}

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

  @impl true
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
      _ -> {:noreply, state}
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
