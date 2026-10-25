defmodule Engram.Analytics.Folds do
  @moduledoc """
  Counters for the occurrences a throttled event stands for. A throttled
  event (`surface_active`, `mcp_tool_called`) is sent once per window; every
  occurrence is counted here and the next event that is sent carries, and
  resets, the count.

  Counts no next event picks up are sent on their own: every 5 minutes and on
  shutdown, each key with pending counts becomes one `<event>_rollup` event
  (`mcp_tool_called_rollup`, `surface_active_rollup`) carrying the counts and
  the props of the last occurrence. Summed with the events, the counts are
  exact and land within 5 minutes of the occurrence, on its day.

  Per node, in ETS. Remaining loss: a hard crash (OOM kill, `kill -9`, power)
  skips the shutdown flush and loses up to 5 minutes of that node's counts.
  A graceful stop (deploy, scale-in) flushes them.

  The timer is off in test (`:analytics_folds_flush_ms` nil); tests call
  `flush/0`.
  """
  use GenServer

  @table :engram_analytics_folds

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Add `counts` (`%{name => n}`) to `key` (`{event, user_id, dedupe}`), and
  keep `props` as what its rollup event carries.
  """
  @spec add(term(), %{atom() => non_neg_integer()}, map()) :: :ok
  def add(key, counts, props \\ %{}) do
    # Counters first, props last: a `take/2` landing between the two steps
    # then strands at most a props row (until that key's next take), never
    # counts with no props, which would roll up without their tool/surface.
    Enum.each(counts, fn {name, n} ->
      :ets.update_counter(@table, {key, name}, n, {{key, name}, 0})
    end)

    true = :ets.insert(@table, {{:props, key}, props})
    :ok
  end

  @doc """
  Read and reset `names` for `key`, as `%{name => n}`. Clears the key's props
  too, so a key the next event picked up leaves nothing in the table.
  """
  @spec take(term(), [atom()]) :: %{atom() => non_neg_integer()}
  def take(key, names) do
    true = :ets.delete(@table, {:props, key})

    Map.new(names, fn name ->
      case :ets.take(@table, {key, name}) do
        [{_, n}] -> {name, n}
        [] -> {name, 0}
      end
    end)
  end

  @doc """
  Send every key's pending counts as its `<event>_rollup` event and reset
  them. Runs in the caller's process (the timer, shutdown, tests).
  """
  @spec flush() :: :ok
  def flush do
    # Counter rows only: `{{key, name}, n}` with an atom name. `{:props, key}`
    # rows have a tuple in that place.
    pending =
      @table
      |> :ets.select([{{{:"$1", :"$2"}, :_}, [{:is_atom, :"$2"}], [{{:"$1", :"$2"}}]}])
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    for {{event, user_id, _dedupe} = key, names} <- pending do
      # Props first: take/2 clears them.
      props = take_props(key)
      counts = take(key, names)

      if Enum.any?(counts, fn {_name, n} -> n > 0 end) do
        Engram.Analytics.track(
          %Engram.Accounts.User{id: user_id},
          event <> "_rollup",
          Map.merge(props, counts)
        )
      end
    end

    :ok
  end

  defp take_props(key) do
    case :ets.take(@table, {:props, key}) do
      [{_, props}] -> props
      [] -> %{}
    end
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
