defmodule Engram.Analytics.Folds do
  @moduledoc """
  Counters for the occurrences a throttled event stands for. A throttled
  event (`surface_active`, `mcp_tool_called`) is sent once per window; every
  occurrence is counted here and the next event that is sent carries, and
  resets, the count.

  Counts no next event picks up are sent on their own: every 5 minutes and on
  shutdown, each key with pending counts becomes one `<event>_rollup` event
  (`mcp_tool_called_rollup`, `surface_active_rollup`) carrying the counts and
  the props of the first occurrence since the key was last sent. Summed with
  the events, the counts are exact and land within 5 minutes of the
  occurrence, on its day.

  Per node, in ETS. Remaining loss: a hard crash (OOM kill, `kill -9`, power)
  skips the shutdown flush and loses up to 5 minutes of that node's counts.
  A graceful stop (deploy, scale-in) flushes them.

  The timer is off in test (`:analytics_folds_flush_ms` nil); tests call
  `flush/0`.
  """
  use GenServer

  @table :engram_analytics_folds

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # A key is ONE row, `{{key, names}, props, n1, n2, ...}`, `names` sorted and
  # the counters in that order. add/take/flush are each one atomic ETS op on
  # it, so no interleaving can ship counts without their props or strand a
  # row: a take or flush lands wholly before or after an add. `names` is in
  # the row key, so a call with another set of counters is its own row
  # rather than a misaligned one.

  @doc """
  Add `counts` (`%{name => n}`) to `key` (`{event, user_id, dedupe}`). `props`
  is what its rollup event carries. One `update_counter`, so `props` is
  written only when this call creates the row: a rollup carries the props of
  the first occurrence since the key was last sent.
  """
  @spec add(term(), %{atom() => non_neg_integer()}, map()) :: :ok
  def add(key, counts, props \\ %{}) do
    {names, ns} = counts |> Enum.sort() |> Enum.unzip()
    ops = ns |> Enum.with_index(3) |> Enum.map(fn {n, pos} -> {pos, n} end)
    default = List.to_tuple([{key, names}, props | Enum.map(ns, fn _ -> 0 end)])
    _ = :ets.update_counter(@table, {key, names}, ops, default)
    :ok
  end

  @doc """
  Read and reset `names` for `key`, as `%{name => n}`. Takes the key's whole
  row, props included, so a key the next event picked up leaves nothing in
  the table.
  """
  @spec take(term(), [atom()]) :: %{atom() => non_neg_integer()}
  def take(key, names) do
    names = Enum.sort(names)

    case :ets.take(@table, {key, names}) do
      [row] -> counts(row)
      [] -> Map.new(names, &{&1, 0})
    end
  end

  @doc """
  Send every key's pending counts as its `<event>_rollup` event and reset
  them. Runs in the caller's process (the timer, shutdown, tests).
  """
  @spec flush() :: :ok
  def flush do
    row_keys = :ets.select(@table, [{:"$1", [], [{:element, 1, :"$1"}]}])

    for {{event, user_id, _dedupe}, _names} = row_key <- row_keys,
        [row] <- [:ets.take(@table, row_key)] do
      counts = counts(row)

      if Enum.any?(counts, fn {_name, n} -> n > 0 end) do
        Engram.Analytics.track(
          %Engram.Accounts.User{id: user_id},
          event <> "_rollup",
          Map.merge(elem(row, 1), counts)
        )
      end
    end

    :ok
  end

  defp counts(row) do
    [{_key, names}, _props | ns] = Tuple.to_list(row)
    Map.new(Enum.zip(names, ns))
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    _table = :ets.new(@table, [:named_table, :set, :public, write_concurrency: true])
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:flush, state) do
    flush()
    schedule()
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    # Off in test: the sandbox is gone by VM stop, so the flush is only noise.
    if Application.get_env(:engram, :analytics_folds_flush_on_terminate, true), do: flush()
    :ok
  end

  defp schedule do
    _ =
      if ms = Application.get_env(:engram, :analytics_folds_flush_ms, :timer.minutes(5)) do
        Process.send_after(self(), :flush, ms)
      end

    :ok
  end
end
