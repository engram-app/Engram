defmodule Engram.MCP.ParseGate do
  @moduledoc """
  Bounds how many markdown parses (`Engram.MCP.Sections`) run at once on this
  node, instead of capping note size.

  The parse is `Engram.Native.md_outline/1` (comrak), on a dirty CPU
  scheduler above 16 KB. It is linear, but dense markup still takes ~1-2 s
  per MB, a dirty NIF cannot be interrupted, and comrak's tree peaks at
  ~100-250x the note in native memory. Unbounded, a few outline calls over
  big notes could occupy every dirty CPU scheduler and stack those peaks.

  `run/2` does the work in a task under `Engram.TaskSupervisor`. The TASK holds
  the slot (the gate monitors it), so the slot is released only when the parse
  really ends: on success, on a crash, or on a kill. The caller only waits:

    * no slot within `:acquire_timeout` (or `:max_waiting` callers already
      queued): `{:error, :busy}`;
    * no result within `:parse_timeout`: `{:error, :parse_timeout}`, while the
      task runs on, keeps its slot, and its late result is discarded;
    * the task crashed: `{:error, :parse_failed}`;
    * the call's `:deadline` (absolute, `System.monotonic_time(:millisecond)`)
      passed, or cut one of those waits short: `{:error, :deadline}`. A run
      whose deadline already passed does no work at all. `call_opts/0` builds
      the options (deadline included) for one MCP tool call.

  A task that gets its slot after its caller died exits without running the
  work. Every run emits `[:engram, :mcp, :section_parse, :stop]` with
  `%{duration: native, bytes: n}` and metadata `%{outcome: ...}` (`:ok`,
  `:busy`, `:timeout`, `:deadline`, `:error`, `:abandoned`); `duration` is
  the caller's wait (slot wait plus parse), so a timed-out parse reports the
  timeout, not its true length. No content or paths.

  Unlike `Engram.Sync.PageGate` (same monitor/withdraw design), this never
  runs the work ungated: a busy node refuses with a fixable error.

  Limits of the guarantee:

    * It bounds how many parses run at once, NOT how long one parse takes.
      One pathological note still holds its slot until comrak returns.
    * The count lives in the gate process. If the gate restarts, the new one
      starts at zero while parses granted by the old one may still be running
      in their tasks, so for a while up to twice the limit can run. Supervisor
      restart intensity bounds how often that can happen.

  Config (`config :engram, Engram.MCP.ParseGate, ...`): `:limit` (slots,
  default `default_limit/1` of this node's dirty CPU schedulers),
  `:acquire_timeout` (ms, 5_000), `:parse_timeout` (ms, 15_000),
  `:max_waiting` (queued callers, 16), `:deadline_ms` (per tool call, 20_000).
  `run/2` opts override the timeouts, `:gate` and `:deadline`; `start_link/1`
  opts override `:limit`, `:max_waiting` and `:name` (`name: nil` starts an
  unregistered gate, for tests). Test seam: options stored under
  `Process.put(:engram_parse_gate_opts, opts)` apply to that process's runs
  and `call_opts/0` (process-local, never global env).
  """
  use GenServer

  @defaults [acquire_timeout: 5_000, parse_timeout: 15_000, max_waiting: 16, deadline_ms: 20_000]
  @seam :engram_parse_gate_opts
  @event [:engram, :mcp, :section_parse, :stop]

  @type error :: :busy | :parse_timeout | :parse_failed | :deadline

  def start_link(opts \\ []) do
    limit = opt(opts, :limit, fn -> default_limit(:erlang.system_info(:dirty_cpu_schedulers)) end)
    init = {limit, opt(opts, :max_waiting)}

    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, init)
      name -> GenServer.start_link(__MODULE__, init, name: name)
    end
  end

  @doc """
  Slots for a node with `dirty` dirty CPU schedulers: all but one, never
  fewer than one. With several, a parse storm leaves one for other dirty
  NIFs. Prod runs ONE (0.5 vCPU, `+SDcpu 1:1`, see rel/env.sh.eex), so
  there a parse does share it: the single slot only means other dirty NIFs
  queue behind at most one parse, and one comrak tree is resident at a time.
  """
  @spec default_limit(pos_integer()) :: pos_integer()
  def default_limit(dirty) when is_integer(dirty), do: max(1, dirty - 1)

  @doc "Options for one MCP tool call: the test seam plus a fresh deadline."
  @spec call_opts() :: keyword()
  def call_opts do
    seam = Process.get(@seam, [])
    Keyword.put(seam, :deadline, now_ms() + opt(seam, :deadline_ms))
  end

  @spec run((-> result), keyword()) :: {:ok, result} | {:error, error()} when result: var
  def run(fun, opts \\ []) do
    opts = Keyword.merge(Process.get(@seam, []), opts)
    start = System.monotonic_time()
    result = do_run(fun, opts)
    emit(outcome(result), start, opts)
    result
  end

  defp do_run(fun, opts) do
    case remaining(opts) do
      left when is_integer(left) and left <= 0 -> {:error, :deadline}
      left -> spawn_run(fun, opts, left)
    end
  end

  defp spawn_run(fun, opts, left) do
    gate = Keyword.get(opts, :gate, __MODULE__)
    {acquire_timeout, cut?} = cap(opt(opts, :acquire_timeout), left)
    caller = self()
    tag = make_ref()

    task =
      Task.Supervisor.async_nolink(Engram.TaskSupervisor, fn ->
        started = System.monotonic_time()
        status = acquire(gate, acquire_timeout)

        cond do
          status != :ok ->
            send(caller, {tag, status})
            :busy

          # Abandoned while queued: nobody will read the result, so do not
          # spend a dirty scheduler on it. Returning releases the slot.
          not Process.alive?(caller) ->
            emit(:abandoned, started, opts)
            :abandoned

          true ->
            send(caller, {tag, :ok})
            {:done, fun.()}
        end
      end)

    await(task, tag, {acquire_timeout, cut?}, opts)
  end

  # The task always reports its acquire outcome first (acquire/2 cannot
  # raise). The `after` is only a backstop: killing a task that never got a
  # slot is safe, and one that did releases it via the gate's monitor.
  defp await(task, tag, {acquire_timeout, acquire_cut?}, opts) do
    receive do
      {^tag, :ok} ->
        {parse_timeout, cut?} = cap(opt(opts, :parse_timeout), remaining(opts))

        case Task.yield(task, parse_timeout) do
          {:ok, {:done, result}} -> {:ok, result}
          {:exit, _reason} -> {:error, :parse_failed}
          # The task keeps running (and holding its slot); drop its reply.
          nil -> ignore(task, if(cut?, do: :deadline, else: :parse_timeout))
        end

      {^tag, :busy} ->
        abandon(task, tag, acquire_cut?)
    after
      backstop(acquire_timeout) -> abandon(task, tag, acquire_cut?)
    end
  end

  defp abandon(task, tag, cut?) do
    _ = Task.shutdown(task, :brutal_kill)

    # Nothing of this run may stay in the caller's mailbox.
    receive do
      {^tag, _} -> :ok
    after
      0 -> :ok
    end

    {:error, if(cut?, do: :deadline, else: :busy)}
  end

  defp backstop(:infinity), do: :infinity
  defp backstop(ms), do: ms + 1_000

  defp ignore(task, error) do
    _ = Task.ignore(task)
    {:error, error}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp remaining(opts) do
    case Keyword.get(opts, :deadline) do
      nil -> :infinity
      deadline -> deadline - now_ms()
    end
  end

  # {wait, true} when the deadline, not the configured timeout, set the wait.
  defp cap(timeout, :infinity), do: {timeout, false}
  defp cap(timeout, left) when timeout == :infinity or left < timeout, do: {max(left, 0), true}
  defp cap(timeout, _left), do: {timeout, false}

  defp outcome({:ok, _}), do: :ok
  defp outcome({:error, :parse_timeout}), do: :timeout
  defp outcome({:error, :parse_failed}), do: :error
  defp outcome({:error, other}), do: other

  defp emit(outcome, start, opts) do
    :telemetry.execute(
      @event,
      %{duration: System.monotonic_time() - start, bytes: Keyword.get(opts, :bytes, 0)},
      %{outcome: outcome}
    )
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

  defp opt(opts, key, default \\ nil) do
    Keyword.get_lazy(opts, key, fn ->
      case Keyword.fetch(Application.get_env(:engram, __MODULE__, []), key) do
        {:ok, value} -> value
        :error -> if default, do: default.(), else: @defaults[key]
      end
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
