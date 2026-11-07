defmodule Engram.Workers.BackfillNameTerms do
  @moduledoc """
  The `NameTerms` backfill (`Engram.DataMigrations.NameTerms`) as one paced
  chain: each hop walks `notes`, then `folders`, in 200-id windows
  (`Engram.Backfill.IdWindows.reduce_all/4`: the fleet on the maintenance
  pool, else per user), healing the stale refs of each window
  (`Engram.Search.NameTerms.heal_window/3`), with a #{250} ms pause between
  windows. A hop stops after #{30} s and inserts its successor at its
  cursor, so the walk resumes where it stopped (a restart costs nothing).
  The chain ends at the end of `folders`; the hourly ledger pass closes the
  migration once no stale ref is left, or starts a new chain.

  Pace: about #{div(200 * 1000, 250 + 50)} refs a second at most (a window's heal
  is a few tens of ms plus the pause), so a 70k-note fleet is about 2 to 5
  minutes of work spread over the hops. Not measured on prod. At most
  #{500} hops per chain (a total budget of about 4 h); a chain that hits it
  ends and the ledger starts the next one.
  """
  use Oban.Worker,
    queue: :crdt_backfill,
    priority: 3,
    max_attempts: 5,
    unique: Engram.Jobs.unique(__MODULE__)

  alias Engram.Backfill.IdWindows
  alias Engram.Folders.Folder
  alias Engram.Notes.Note
  alias Engram.Search.NameTerms

  @hop_ms 30_000
  @pause_ms 250
  @max_hops 500
  @tables %{"notes" => Note, "folders" => Folder}

  @doc "The chain's first hop."
  def start, do: new(%{"table" => "notes"})

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    table = Map.get(args, "table", "notes")
    hop = Map.get(args, "hop", 0)
    from = cursor(args)
    deadline = System.monotonic_time(:millisecond) + Map.get(args, "hop_ms", @hop_ms)
    pause = Map.get(args, "pause_ms", @pause_ms)

    step = fn ids, ctx, _acc ->
      _ = NameTerms.heal_window(@tables[table], ids, ctx)
      at = {ctx.user_id, List.last(ids)}

      if System.monotonic_time(:millisecond) > deadline do
        {:halt, {:stopped, at}}
      else
        Process.sleep(pause)
        {:cont, {:walked, at}}
      end
    end

    {:ok, result} = IdWindows.reduce_all(@tables[table], {:walked, nil}, step, from: from)

    case {result, table} do
      {{:stopped, {user, after_id}}, _} when hop + 1 < @max_hops ->
        successor(args, %{"table" => table, "user" => user, "after" => after_id, "hop" => hop + 1})

      {{:stopped, _}, _} ->
        :ok

      {_walked, "notes"} ->
        successor(args, %{"table" => "folders", "hop" => hop + 1})

      {_walked, "folders"} ->
        :ok
    end
  end

  defp cursor(%{"after" => after_id} = args) when is_binary(after_id),
    do: {Map.get(args, "user"), after_id}

  defp cursor(_args), do: nil

  # Test knobs ride along.
  defp successor(args, next) do
    {:ok, _} = Oban.insert(new(Map.merge(Map.take(args, ["hop_ms", "pause_ms"]), next)))
    :ok
  end
end
