defmodule Engram.MCP.ParseGate do
  @moduledoc """
  Bounds how many markdown parses (`Engram.MCP.Sections`) run at once on this
  node, instead of capping note size.

  A comrak parse is a dirty-CPU NIF: linear, but pathological markup can take
  seconds per MB, and a dirty NIF cannot be interrupted. Unbounded, a few
  outline calls over big notes could occupy every dirty CPU scheduler.

  `run/2` does the work in a task under `Engram.TaskSupervisor`. The TASK holds
  the slot (the gate monitors it), so the slot is released only when the parse
  really ends: on success, on a crash, or on a kill. The caller only waits:

    * no slot within `:acquire_timeout` (or `:max_waiting` callers already
      queued): `{:error, :busy}`;
    * no result within `:parse_timeout`: `{:error, :parse_timeout}`, while the
      task runs on, keeps its slot, and its late result is discarded;
    * the task crashed: `{:error, :parse_failed}`.

  Unlike `Engram.Sync.PageGate` (same monitor/withdraw design), this never
  runs the work ungated: a busy node refuses with a fixable error.

  Config (`config :engram, Engram.MCP.ParseGate, ...`): `:limit` (slots,
  default 2), `:acquire_timeout` (ms, 5_000), `:parse_timeout` (ms, 15_000),
  `:max_waiting` (queued callers, 16). `run/2` opts override the timeouts and
  `:gate`; `start_link/1` opts override `:limit`, `:max_waiting` and `:name`
  (`name: nil` starts an unregistered gate, for tests).
  """
  use GenServer

  @defaults [limit: 2, acquire_timeout: 5_000, parse_timeout: 15_000, max_waiting: 16]

  @type error :: :busy | :parse_timeout | :parse_failed

  def start_link(opts \\ []) do
    init = {opt(opts, :limit), opt(opts, :max_waiting)}

    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, init)
      name -> GenServer.start_link(__MODULE__, init, name: name)
    end
  end

  @spec run((-> result), keyword()) :: {:ok, result} | {:error, error()} when result: var
  def run(fun, opts \\ []) do
    gate = Keyword.get(opts, :gate, __MODULE__)
    acquire_timeout = opt(opts, :acquire_timeout)
    caller = self()
    tag = make_ref()

    task =
      Task.Supervisor.async_nolink(Engram.TaskSupervisor, fn ->
        status = acquire(gate, acquire_timeout)
        send(caller, {tag, status})
        if status == :ok, do: {:done, fun.()}, else: :busy
      end)

    await(task, tag, acquire_timeout, opt(opts, :parse_timeout))
  end

  # The task always reports its acquire outcome first (acquire/2 cannot
  # raise). The `after` is only a backstop: killing a task that never got a
  # slot is safe, and one that did releases it via the gate's monitor.
  defp await(task, tag, acquire_timeout, parse_timeout) do
    receive do
      {^tag, :ok} ->
        case Task.yield(task, parse_timeout) do
          {:ok, {:done, result}} -> {:ok, result}
          {:exit, _reason} -> {:error, :parse_failed}
          # The task keeps running (and holding its slot); drop its reply.
          nil -> ignore(task)
        end

      {^tag, :busy} ->
        _ = Task.shutdown(task, :brutal_kill)
        {:error, :busy}
    after
      backstop(acquire_timeout) ->
        _ = Task.shutdown(task, :brutal_kill)
        {:error, :busy}
    end
  end

  defp backstop(:infinity), do: :infinity
  defp backstop(ms), do: ms + 1_000

  defp ignore(task) do
    _ = Task.ignore(task)
    {:error, :parse_timeout}
  end

  defp acquire(gate, timeout) do
    GenServer.call(gate, :acquire, timeout)
  catch
    :exit, _ ->
      # Timed out or the gate is down. Withdraw first: a grant can race the
      # timeout, and this task is still alive until it returns :busy.
      # Cast, not call: a second blocking call on the failure path could hang.
      GenServer.cast(gate, {:cancel, self()})
      :busy
  end

  defp opt(opts, key) do
    Keyword.get_lazy(opts, key, fn ->
      :engram |> Application.get_env(__MODULE__, []) |> Keyword.get(key, @defaults[key])
    end)
  end

  @impl true
  def init({limit, max_waiting}),
    do: {:ok, %{limit: limit, max_waiting: max_waiting, active: %{}, waiting: :queue.new()}}

  @impl true
  def handle_call(:acquire, {pid, _} = from, state) do
    cond do
      map_size(state.active) < state.limit -> {:reply, :ok, grant(state, pid)}
      :queue.len(state.waiting) >= state.max_waiting -> {:reply, :busy, state}
      true -> {:noreply, %{state | waiting: :queue.in(from, state.waiting)}}
    end
  end

  @impl true
  def handle_cast({:cancel, pid}, state) do
    waiting = :queue.filter(fn {waiter, _} -> waiter != pid end, state.waiting)
    {:noreply, %{state | waiting: waiting} |> drop(pid) |> pump()}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, state |> drop(pid) |> pump()}

  # One slot per task pid: each run/2 spawns a fresh task, so no re-entry.
  defp grant(state, pid), do: %{state | active: Map.put(state.active, pid, Process.monitor(pid))}

  defp drop(state, pid) do
    case Map.pop(state.active, pid) do
      {nil, _} ->
        state

      {ref, rest} ->
        Process.demonitor(ref, [:flush])
        %{state | active: rest}
    end
  end

  # Hands a freed slot to the next live waiter (a dead one could never
  # release it).
  defp pump(state) do
    with true <- map_size(state.active) < state.limit,
         {{:value, {pid, _} = from}, rest} <- :queue.out(state.waiting) do
      state = %{state | waiting: rest}

      if Process.alive?(pid) do
        GenServer.reply(from, :ok)
        grant(state, pid)
      else
        pump(state)
      end
    else
      _ -> state
    end
  end
end
