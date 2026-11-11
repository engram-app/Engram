defmodule Engram.Backfill.PacedChain do
  @moduledoc """
  One hop of a paced backfill chain: walks one table's id windows
  (`Engram.Backfill.IdWindows.reduce_all/4`, fleet or per user) from a
  cursor, heals each window, and stops when the hop's budget says so. The
  worker that owns the chain keeps the cursor in its job args and inserts its
  own successor, so a walk spans hops on any node and a restart resumes where
  it stopped. Shared by `Engram.Workers.BackfillNameTerms` (S1) and
  `Engram.Workers.BackfillNoteNames` (S2); each keeps its own args, pacing
  and end-of-walk rule.

  Every hop heals at least one window, so a chain always progresses.
  """

  alias Engram.Backfill.{IdWindows, Throttle}

  # The pause between windows of every paced chain: the one knob.
  @pause_ms 250

  @type cursor :: IdWindows.cursor()

  @doc """
  Walks `schema` from `from` (nil: the start). `step.(ids, ctx, acc)` heals
  one window and returns the new `acc`. After each window `stop?.(acc)` is
  asked: true ends the hop with `{:stopped, cursor, acc}` (the cursor of that
  window); otherwise the walk sleeps `:pause_ms` (default `pause_ms/0`) and
  goes on.
  `{:walked, acc}` when the table ended first.

  `:continue?` (a 0-arity fun, default always true) is asked BEFORE each
  window, a kill switch: false ends the hop with `{:aborted, acc}` and that
  window is not healed.

  `:writes_per_s` (optional) is the hop's ceiling: after each window the
  walk sleeps long enough that `writes.(acc)` (required with it: the rows the
  hop has written so far) stays at or under it a second, never less than
  the pause (`Engram.Backfill.Throttle.wait_ms/5`). The window that stops the
  hop waits off its deficit too, so a chain whose next hop starts at once
  still keeps to the ceiling.

  `:started_ms` (`Throttle.now_ms/0` clock, default now) is when the hop
  began: a hop that walks several tables passes its own start, so `writes`
  counted across tables are measured against the whole hop.

  `:clock` (0-arity, ms, default `Throttle.now_ms/0`) and `:sleep` (1-arity,
  default `Process.sleep/1`) are the seams a test injects to check the waits
  without sleeping.

  Options: `:stop?` (required), `:continue?`, `:pause_ms`, `:writes_per_s`,
  `:writes`, `:started_ms`, `:clock` and `:sleep`, and `IdWindows.reduce/5`'s `:batch_size` and
  `:fun_in_tenant`.
  """
  @spec walk(module(), cursor(), acc, (list(), IdWindows.ctx(), acc -> acc), keyword()) ::
          {:stopped, cursor(), acc} | {:walked, acc} | {:aborted, acc}
        when acc: term()
  def walk(schema, from, acc, step, opts) do
    stop? = Keyword.fetch!(opts, :stop?)
    continue? = Keyword.get(opts, :continue?, fn -> true end)
    pause = Keyword.get(opts, :pause_ms, @pause_ms)
    clock = Keyword.get(opts, :clock, &Throttle.now_ms/0)
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)
    started = Keyword.get_lazy(opts, :started_ms, clock)

    wait =
      waiter(pause, Keyword.get(opts, :writes_per_s), Keyword.get(opts, :writes), started, clock)

    fun = fn ids, ctx, {_state, at, acc} ->
      if continue?.() do
        acc = step.(ids, ctx, acc)
        at = {ctx.user_id, List.last(ids)}

        stop = stop?.(acc)
        # A stopping window waits off its ceiling deficit too (never the
        # pause): the owner may start its successor at once.
        ms = wait.(acc, stop)
        if ms > 0, do: sleep.(ms)

        if stop, do: {:halt, {:stopped, at, acc}}, else: {:cont, {:walking, at, acc}}
      else
        {:halt, {:aborted, at, acc}}
      end
    end

    walk_opts = [from: from] ++ Keyword.take(opts, [:batch_size, :fun_in_tenant])
    {:ok, result} = IdWindows.reduce_all(schema, {:walking, from, acc}, fun, walk_opts)

    case result do
      {:stopped, at, acc} -> {:stopped, at, acc}
      {:aborted, _at, acc} -> {:aborted, acc}
      {:walking, _at, acc} -> {:walked, acc}
    end
  end

  defp waiter(pause, nil, _writes, _started, _clock),
    do: fn _acc, stop -> if stop, do: 0, else: pause end

  defp waiter(pause, per_s, writes, started, clock) when is_function(writes, 1) do
    fn acc, stop ->
      Throttle.wait_ms(
        started,
        writes.(acc),
        per_s,
        if(stop, do: 0, else: pause),
        clock.()
      )
    end
  end

  @doc "The default pause between windows (ms)."
  @spec pause_ms() :: 250
  def pause_ms, do: @pause_ms

  @doc "A hop deadline `ms` from now, for `past?/1`."
  @spec deadline(number()) :: number()
  def deadline(ms), do: System.monotonic_time(:millisecond) + ms

  @doc "True once `deadline/1`'s moment has passed."
  @spec past?(number()) :: boolean()
  def past?(deadline), do: System.monotonic_time(:millisecond) > deadline
end
