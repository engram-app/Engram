defmodule Engram.Workers.ReconcileNotePayloads do
  @moduledoc """
  Heals Qdrant points whose note-level payload (the filter HMACs and dates,
  `Engram.Indexing.expected_note_payload/1`) no longer matches their note's
  row, one user per chain. Run by the `NotePayloadStamps` data migration.

  The case it exists for: a DEK rotation before the rotation rewrote filter
  HMACs. It rekeyed the rows but left every point on the old key, so a
  type/tag/folder/path filter matched nothing, and nothing re-indexed.

  A note is checked while its `payload_hash` is NULL (written before the
  column existed, or never stamped since). Its points are READ (payload keys
  only); if every one already holds the expected payload the row is just
  stamped, otherwise the payload is rewritten with `set_payload` (never an
  upsert: vectors and text are untouched, no embedder call). Either way the
  note is stamped and leaves the selection, so the chain converges. A note
  whose points are all gone is stamped too: nothing here can repair a
  missing point, and the next index re-creates it.

  Rate-limited: one batch of 200 notes costs one scroll per 2048 points
  plus a `set_payload` per drifted note, with a pause between batches, on the
  single-slot `crdt_backfill` lane.
  """
  # One chain per user, as `BackfillLinkKeys`: `:executing` is not a unique
  # state, so a job can insert its own successor.
  use Oban.Worker,
    queue: :crdt_backfill,
    priority: 3,
    max_attempts: 5,
    unique: [keys: [:user_id], period: :infinity, states: [:available, :scheduled, :retryable]]

  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Backfill.TenantScan
  alias Engram.Crypto.RotationGate
  alias Engram.Indexing
  alias Engram.Logger.Metadata
  alias Engram.Notes.{Chunk, Note}
  alias Engram.Repo
  alias Engram.Vector.Qdrant

  require Logger

  @batch_size 200
  @budget_ms 30_000
  # Between batches, so a large vault never saturates Qdrant.
  @pause_ms 200

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id} = args}) do
    with %User{} = user <- Repo.get(User, user_id),
         :ok <- RotationGate.check_user(user) do
      deadline = System.monotonic_time(:millisecond) + @budget_ms

      case heal(user_id, args["after"], deadline) do
        :done ->
          :ok

        {:more, after_id} ->
          {:ok, _} = Oban.insert(new(%{"user_id" => user_id, "after" => after_id}))
          :ok

        {:error, _} = err ->
          err
      end
    else
      nil -> :ok
      {:error, :rotation_in_progress} -> {:snooze, 60}
    end
  end

  @doc "Enqueues a chain for every user with an unstamped indexed note. Returns how many."
  @spec enqueue_missing() :: non_neg_integer()
  def enqueue_missing do
    user_ids =
      TenantScan.flat_map_users(fn uid ->
        if Repo.exists?(where(unstamped(), [n], n.user_id == ^uid)), do: [uid], else: []
      end)

    executing = executing_user_ids()

    # One insert per user: Oban's Basic engine ignores `unique` in insert_all.
    for uid <- user_ids,
        not MapSet.member?(executing, uid),
        do: {:ok, _} = Oban.insert(new(%{"user_id" => uid}))

    length(user_ids)
  end

  # The done predicate and the worker's selection, one definition.
  defp unstamped do
    from(n in Note,
      as: :note,
      where:
        n.kind == "note" and is_nil(n.payload_hash) and
          exists(
            from(c in Chunk,
              where: c.note_id == parent_as(:note).id and not is_nil(c.qdrant_point_id)
            )
          )
    )
  end

  defp executing_user_ids do
    from(j in Oban.Job,
      where: j.worker == ^inspect(__MODULE__) and j.state == "executing",
      select: fragment("?->>'user_id'", j.args)
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp heal(user_id, after_id, deadline) do
    {notes, points} = batch(user_id, after_id)

    cond do
      notes == [] ->
        :done

      System.monotonic_time(:millisecond) > deadline ->
        {:more, after_id}

      true ->
        with {:ok, stored} <- read_payloads(points |> Map.values() |> List.flatten()),
             :ok <- heal_notes(notes, points, stored) do
          if length(notes) < @batch_size do
            :done
          else
            Process.sleep(@pause_ms)
            heal(user_id, List.last(notes).id, deadline)
          end
        end
    end
  end

  defp batch(user_id, after_id) do
    query =
      from(n in unstamped(), where: n.user_id == ^user_id, order_by: n.id, limit: @batch_size)

    query = if after_id, do: where(query, [n], n.id > ^after_id), else: query

    {:ok, result} =
      Repo.with_tenant(user_id, fn ->
        notes = Repo.all(query)
        ids = Enum.map(notes, & &1.id)

        points =
          from(c in Chunk,
            where: c.note_id in ^ids and not is_nil(c.qdrant_point_id),
            select: {c.note_id, c.qdrant_point_id}
          )
          |> Repo.all()
          |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

        {notes, points}
      end)

    result
  end

  # `%{point_id => payload}` for the points that exist, payload keys only.
  defp read_payloads(ids) do
    keys = Indexing.expected_note_payload(%Note{}) |> Map.keys() |> Enum.map(&to_string/1)

    ids
    |> Enum.chunk_every(Qdrant.max_ids())
    |> Enum.reduce_while({:ok, %{}}, fn chunk, {:ok, acc} ->
      case Qdrant.scroll(Qdrant.collection_name(),
             filter: %{must: [%{has_id: chunk}]},
             with_payload: keys,
             limit: length(chunk)
           ) do
        {:ok, %{points: points}} ->
          {:cont, {:ok, Enum.into(points, acc, &{&1["id"], &1["payload"] || %{}})}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  defp heal_notes(notes, points, stored) do
    Enum.reduce_while(notes, :ok, fn note, :ok ->
      payload = Indexing.expected_note_payload(note)
      want = payload |> Jason.encode!() |> Jason.decode!()
      present = for id <- Map.get(points, note.id, []), Map.has_key?(stored, id), do: id
      drifted = Enum.reject(present, &holds?(stored[&1], want))

      result =
        if drifted == [],
          do: Indexing.stamp_note_payload_hash(note, payload),
          else: Indexing.rewrite_note_payload(note, drifted)

      case result do
        :ok ->
          {:cont, :ok}

        {:error, reason} = err ->
          Logger.warning(
            "note payload reconcile: set_payload failed",
            Metadata.with_category(:warning, :search,
              user_id: note.user_id,
              note_id: note.id,
              reason_label: Metadata.safe_reason(reason)
            )
          )

          {:halt, err}
      end
    end)
  end

  # A null and an absent key are the same to a filter.
  defp holds?(point, want), do: Enum.all?(want, fn {k, v} -> Map.get(point, k) == v end)
end
