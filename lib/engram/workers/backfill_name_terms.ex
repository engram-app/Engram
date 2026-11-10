defmodule Engram.Workers.BackfillNameTerms do
  @moduledoc """
  The `NameTerms` backfill (`Engram.DataMigrations.NameTerms`) as one paced
  chain: each hop walks `notes`, then `folders`, in 200-id windows
  (`Engram.Backfill.PacedChain.walk/5` over `IdWindows.reduce_all/4`: the
  fleet on the maintenance pool, else per user), healing the stale refs of each window
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
  pressure gate (`Throttle.pressure/0`: app pool queue, oldest open
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

  alias Engram.Backfill.{PacedChain, Throttle}
  alias Engram.DataMigrations.NameTerms, as: Ledger
  alias Engram.Folders.Folder
  alias Engram.Notes.Note
  alias Engram.Search.NameTerms

  @hop_ms 30_000
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

      reason = Throttle.pressure() ->
        {:ok, _} = Oban.insert(new(args, schedule_in: @held_s))
        Throttle.log_pass("name_terms", written: 0, held: reason, elapsed_ms: 0)

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
    max_rows = Ledger.max_rows()
    fixed0 = Map.get(args, "fixed", 0)

    result =
      PacedChain.walk(
        @tables[table],
        from,
        fixed0,
        fn ids, ctx, n -> n + NameTerms.heal_window(@tables[table], ids, ctx) end,
        [
          stop?: fn n -> Throttle.now_ms() > deadline or n - fixed0 >= max_rows end,
          pause_ms: Map.get(args, "pause_ms", PacedChain.pause_ms()),
          writes: &(&1 - fixed0),
          writes_per_s: Ledger.writes_per_s(),
          # The kill switch is read per window, so it stops a running chain.
          continue?: &Ledger.enabled?/0
        ] ++ batch_size(args)
      )

    {status, fixed} = outcome(result)

    Throttle.log_pass("name_terms",
      written: fixed - fixed0,
      held: :none,
      elapsed_ms: Throttle.now_ms() - started,
      left: Ledger.left(),
      result: status
    )

    case {result, table} do
      {{:aborted, _fixed}, _} ->
        :ok

      {{:stopped, {user, after_id}, fixed}, _} when hop + 1 < @max_hops ->
        successor(args, %{
          "table" => table,
          "user" => user,
          "after" => after_id,
          "hop" => hop + 1,
          "fixed" => fixed
        })

      {{:stopped, _at, _fixed}, _} ->
        :ok

      {{:walked, fixed}, "notes"} ->
        successor(args, %{"table" => "folders", "hop" => hop + 1, "fixed" => fixed})

      {{:walked, fixed}, "folders"} ->
        Ledger.walked(fixed)
    end
  end

  defp outcome({:stopped, _at, fixed}), do: {:stopped, fixed}
  defp outcome({status, fixed}), do: {status, fixed}

  defp cursor(%{"after" => after_id} = args) when is_binary(after_id),
    do: {Map.get(args, "user"), after_id}

  defp cursor(_args), do: nil

  defp batch_size(%{"batch_size" => n}) when is_integer(n), do: [batch_size: n]
  defp batch_size(_args), do: []

  # Test knobs ride along.
  defp successor(args, next) do
    {:ok, _} =
      Oban.insert(new(Map.merge(Map.take(args, ["hop_ms", "pause_ms", "batch_size"]), next)))

    :ok
  end
end
