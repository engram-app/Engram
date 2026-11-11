defmodule Engram.Workers.BackfillNameTerms do
  @moduledoc """
  The `NameTerms` backfill (`Engram.DataMigrations.NameTerms`) as one paced
  chain: each hop walks `notes`, then `folders`, in 200-id windows
  (`Engram.Backfill.IdWindows.reduce_all/4`: the fleet on the maintenance
  pool, else per user), healing the stale refs of each window
  (`Engram.Search.NameTerms.heal_window/3`), with a #{250} ms pause between
  windows. A hop stops after #{30} s and inserts its successor at its
  cursor, so the walk resumes where it stopped (a restart costs nothing).
  The chain ends at the end of `folders` and records how many refs the
  whole walk fixed (`Ledger.walked/1`); the hourly ledger pass closes the
  migration once no stale ref is left, or starts a new chain, but not within
  a day of a complete walk that fixed nothing (those refs need a writer, not
  another O(table) walk). The `name_terms_backfill` kill switch is read per
  window: off stops a running chain at once, with no successor.

  Pace (`Engram.Backfill.Throttle`): a hop heals at most
  `Ledger.max_rows/0` refs (default 1,000; checked after each window, so a
  hop can pass it by one window), and after each window sleeps long enough
  that its refs stay at or under `Ledger.writes_per_s/0` a second (default
  150), never less than the 250 ms pause. At prod size (~170k notes, ~44k
  folders, 1,655 users) that is about 24 min of walking. Before a hop, the
  pressure gate (`Throttle.pressure/1`: app pool queue, oldest open
  transaction) can hold it: the hop is re-inserted #{60} s later with the
  same cursor and writes nothing. The kill switch is read first, so an off
  chain is never re-inserted. At most #{500} hops per chain; a chain that hits
  it ends and the ledger starts the next one.
  """
  use Oban.Worker,
    queue: :crdt_backfill,
    priority: 3,
    max_attempts: 5,
    unique: Engram.Jobs.unique(__MODULE__)

  alias Engram.Backfill.{IdWindows, Throttle}
  alias Engram.DataMigrations.NameTerms, as: Ledger
  alias Engram.Folders.Folder
  alias Engram.Notes.Note
  alias Engram.Search.NameTerms

  @hop_ms 30_000
  @pause_ms 250
  @max_hops 500
  @held_s 60
  @tables %{"notes" => Note, "folders" => Folder}

  # A hop works 30 s plus one window; a hung one is killed well before the
  # queue notices.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(2)

  @doc "The chain's first hop."
  def start, do: new(%{"table" => "notes"})

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    cond do
      not Ledger.enabled?() ->
        :ok

      Throttle.pressure("name_terms") ->
        {:ok, _} = Oban.insert(new(args, schedule_in: @held_s))
        :ok

      true ->
        hop(args)
    end
  end

  defp hop(args) do
    table = Map.get(args, "table", "notes")
    hop = Map.get(args, "hop", 0)
    from = cursor(args)
    started = Throttle.now_ms()
    deadline = started + Map.get(args, "hop_ms", @hop_ms)
    pause = Map.get(args, "pause_ms", @pause_ms)
    max_rows = Ledger.max_rows()
    per_s = Ledger.writes_per_s()

    fixed0 = Map.get(args, "fixed", 0)

    # The kill switch is read per window, so it stops a running chain.
    step = fn ids, ctx, {_status, _at, n} ->
      if Ledger.enabled?() do
        n = n + NameTerms.heal_window(@tables[table], ids, ctx)
        at = {ctx.user_id, List.last(ids)}
        now = Throttle.now_ms()

        if now > deadline or n - fixed0 >= max_rows do
          {:halt, {:stopped, at, n}}
        else
          Process.sleep(Throttle.wait_ms(started, n - fixed0, per_s, pause, now))
          {:cont, {:walked, at, n}}
        end
      else
        {:halt, {:killed, nil, n}}
      end
    end

    walk_opts = [from: from] ++ batch_size(args)

    {:ok, {status, at, fixed}} =
      IdWindows.reduce_all(@tables[table], {:walked, nil, fixed0}, step, walk_opts)

    case {status, table} do
      {:killed, _} ->
        :ok

      {:stopped, _} when hop + 1 < @max_hops ->
        {user, after_id} = at

        successor(args, %{
          "table" => table,
          "user" => user,
          "after" => after_id,
          "hop" => hop + 1,
          "fixed" => fixed
        })

      {:stopped, _} ->
        :ok

      {:walked, "notes"} ->
        successor(args, %{"table" => "folders", "hop" => hop + 1, "fixed" => fixed})

      {:walked, "folders"} ->
        Ledger.walked(fixed)
    end
  end

  defp cursor(%{"after" => after_id} = args) when is_binary(after_id),
    do: {Map.get(args, "user"), after_id}

  defp cursor(_args), do: nil

  defp batch_size(%{"batch_size" => n}) when is_integer(n), do: [batch_size: n]
  defp batch_size(_args), do: []

  # Test knobs ride along.
  defp successor(args, next) do
    {:ok, _} = Oban.insert(new(Map.merge(Map.take(args, ["hop_ms", "pause_ms", "batch_size"]), next)))
    :ok
  end
end
