defmodule Engram.Workers.ReconcileKeywordIndex do
  @moduledoc """
  Keeps the kwsearch keyword index equal to Postgres with no operator step
  (search storage roadmap P2 tasks 3 and 5): the first bulk load of existing
  notes, every reload after an index change, and the drift and orphan
  repair. All of it through the bulk endpoint
  (`Engram.KeywordStore.Tantivy.Bulk`), never through `keyword_feed` (F2).

  ## Version stamp + reconcile

  The walk's target is `"<kwsearch epoch>:<@version>"`. kwsearch starts a new
  epoch for a new index and after a feed gap, and stays `rebuilding` (not
  serving) until told the epoch is loaded. `@version` is bumped here when the
  docs a note produces change. A target the stored cursor has not finished
  is a FULL walk: every note with chunk rows plus every note kwsearch lists.
  A full walk that skipped no note tells a rebuilding kwsearch
  (`Client.rebuilt/1`); one that skipped notes does not, and runs again a
  day later (a partial index never serves).

  A kwsearch that reports `rebuilding` for a target this cursor already
  finished (a snapshot restored from before the load ended, or a lost
  `rebuilt` call) gets a new full walk, never a bare `rebuilt` (review M4).

  After that, a DIFF walk runs daily: per page of a user's notes, kwsearch's
  doc counts (`Client.notes/4`, the same id range) against the chunk rows.
  Only notes that differ are pushed; a note kwsearch holds that Postgres no
  longer has (gone or trashed) is pushed with an empty point set, the Tantivy
  orphan pass (index docs vs chunk rows).

  ## Bounded per job (review H2)

  The cursor names a user AND a note inside them (`Engram.Maintenance.Cursor`),
  so a walk resumes mid-user. Postgres pages are #{500} notes; reads are
  grouped to at most #{8_000_000} content bytes (`note_bodies.content_bytes`)
  and #{200} notes, one tenant per transaction; one job stops after
  #{64_000_000} bytes or #{4} minutes and chains the next 60 s out. A note
  bigger than a read goes alone. So a huge user makes steady progress and no
  job holds more than one read group's content.

  A user mid DEK rotation or a kwsearch error halts the run where it is; a
  run's outcome is `[:engram, :keyword_reconcile, :run]` (`outcome`, notes
  pushed and skipped).

  ## One walk at a time

  One queued job (`Engram.Jobs`: by worker, any args), and the body runs
  under a session advisory lock, so the hourly cron landing on a running
  walk exits at once (review M7).

  A no-op unless the feed is written (`Engram.KeywordStore.feed?/0`, off by
  default) and `:keyword_reconcile` is not false (runtime kill switch,
  default on). It never changes what searches read. Soft-deleted accounts
  are not walked; their kwsearch docs stay until the purge (as the feed
  writes nothing for a reversible soft delete).
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: Engram.Jobs.unique(__MODULE__)

  import Bitwise
  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Crypto.RotationGate
  alias Engram.KeywordStore
  alias Engram.KeywordStore.Tantivy.Bulk
  alias Engram.KeywordStore.Tantivy.Client
  alias Engram.Logger.Metadata
  alias Engram.Maintenance.Cursor
  alias Engram.Notes.{Chunk, Note, NoteBody}
  alias Engram.Repo
  alias Engram.ServiceConfig

  require Logger

  # Bump when the docs a note produces change shape (not for tokenizer
  # changes: those re-upsert through the resparse and the feed).
  @version 1
  @cursor "keyword_reconcile"
  @lock "keyword_reconcile"
  @page 500
  @read_bytes 8_000_000
  @read_notes 200
  @job_bytes 64_000_000
  @job_ms :timer.minutes(4)
  @every_s 60
  @diff_every_s 86_400

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  @doc "False while the `:keyword_reconcile` kill switch is off."
  @spec enabled?() :: boolean()
  def enabled?, do: ServiceConfig.get(:keyword_reconcile, true) != false

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    with true <- KeywordStore.feed?() and enabled?(),
         {:ok, epoch} <- Client.epoch() do
      case locked(fn -> run(epoch, System.system_time(:second)) end) do
        :busy ->
          :ok

        result ->
          _ =
            if result == :more, do: {:ok, _} = %{} |> new(schedule_in: @every_s) |> Oban.insert()

          {:ok, result}
      end
    else
      _off_or_unreachable -> :ok
    end
  end

  # A session advisory lock on one checked-out connection for the whole
  # run: a second job (the cron landing on a running walk) gets `:busy`.
  defp locked(fun) do
    Repo.checkout(fn ->
      %{rows: [[got?]]} =
        Repo.query!("SELECT pg_try_advisory_lock(hashtextextended($1, 0))", [@lock])

      if got? do
        try do
          fun.()
        after
          Repo.query!("SELECT pg_advisory_unlock(hashtextextended($1, 0))", [@lock])
        end
      else
        :busy
      end
    end)
  end

  @doc """
  One run against kwsearch at `epoch` (`Client.epoch/0`): `:more` while the
  walk has work left, `:done` when this run finished it, `:idle` when there
  was nothing due, `:halted` when it stopped on an error.
  """
  @spec run(%{id: String.t(), rebuilding: boolean()}, integer()) ::
          :more | :done | :idle | :halted
  def run(epoch, now) do
    target = "#{epoch.id}:#{@version}"
    cursor = Cursor.get(@cursor) || %{}

    case walk(cursor, target, epoch, now) do
      :idle -> :idle
      walk -> step(walk, epoch, now)
    end
  end

  defp walk(cursor, target, epoch, now) do
    done_at = cursor["done_at"]
    full = %{"target" => target, "mode" => "full", "skipped" => 0}

    cond do
      cursor["target"] != target -> full
      is_nil(done_at) -> cursor
      # Finished, yet kwsearch still waits: a restored mid-load snapshot or a
      # lost `rebuilt`. Reload (a walk that skipped notes waits a day first).
      epoch.rebuilding and (cursor["skipped"] || 0) == 0 -> full
      now - done_at >= @diff_every_s and epoch.rebuilding -> full
      now - done_at >= @diff_every_s -> %{full | "mode" => "diff"}
      true -> :idle
    end
  end

  defp step(walk, epoch, now) do
    budget = %{bytes: @job_bytes, until: System.monotonic_time(:millisecond) + @job_ms}
    {result, walk, stats} = advance(walk, budget, %{pushed: 0, skipped: 0})

    result =
      case result do
        :finished ->
          :ok = Cursor.put(@cursor, Map.merge(walk, %{"done_at" => now, "user" => nil}))

          _ =
            if walk["mode"] == "full" and (walk["skipped"] || 0) == 0 and epoch.rebuilding,
              do: Client.rebuilt(epoch.id)

          :done

        other ->
          other
      end

    :telemetry.execute([:engram, :keyword_reconcile, :run], stats, %{
      outcome: result,
      mode: walk["mode"]
    })

    result
  end

  # Users in id order; inside one, its notes in pages from `walk["note"]`.
  defp advance(walk, budget, stats) do
    user = walk["user"] || next_user(walk["after_user"])

    cond do
      is_nil(user) ->
        {:finished, walk, stats}

      spent?(budget) ->
        {:more, walk, stats}

      true ->
        walk = Map.put(walk, "user", user)

        case sync_page(user, walk["mode"], walk["note"], budget) do
          {:ok, next_note, budget, got} ->
            stats = add(stats, got)
            walk = Map.put(walk, "skipped", (walk["skipped"] || 0) + got.skipped)

            walk =
              if next_note == :end,
                do: Map.merge(walk, %{"after_user" => user, "user" => nil, "note" => nil}),
                else: Map.put(walk, "note", next_note)

            :ok = Cursor.put(@cursor, walk)
            advance(walk, budget, stats)

          {:error, reason} ->
            Logger.warning(
              "keyword reconcile halted",
              Metadata.with_category(:warning, :search,
                user_id: user,
                reason: Metadata.safe_reason(reason)
              )
            )

            {:halted, walk, stats}
        end
    end
  end

  defp spent?(budget),
    do: budget.bytes <= 0 or System.monotonic_time(:millisecond) >= budget.until

  defp add(stats, got),
    do: %{pushed: stats.pushed + got.pushed, skipped: stats.skipped + got.skipped}

  # `users` carries no RLS (Engram.Backfill.TenantScan): the id walk needs no
  # tenant.
  defp next_user(after_id) do
    from(u in User, where: is_nil(u.deleted_at), order_by: u.id, limit: 1, select: u.id)
    |> then(fn q -> if after_id, do: where(q, [u], u.id > ^after_id), else: q end)
    |> Repo.one()
  end

  @doc "A whole user in one call, unbudgeted (tests and the console)."
  @spec sync_user(String.t(), String.t()) :: :ok | {:error, term()}
  def sync_user(user_id, mode), do: sync_from(to_string(user_id), mode, nil)

  defp sync_from(user_id, mode, after_note) do
    budget = %{bytes: 1 <<< 62, until: System.monotonic_time(:millisecond) + :timer.hours(24)}

    case sync_page(user_id, mode, after_note, budget) do
      {:ok, :end, _budget, _got} -> :ok
      {:ok, next, _budget, _got} -> sync_from(user_id, mode, next)
      {:error, _} = error -> error
    end
  end

  @doc """
  One page of `user_id`'s notes after `after_note` (nil: the first page):
  compares, reads and pushes what differs (`"diff"`) or all of it
  (`"full"`), in byte-bounded read groups, within `budget` (`:bytes` left,
  a monotonic `:until`; optional `:page` and `:read_bytes` override the
  page and read-group sizes). Returns the note
  id to resume after (`:end` once the user is done) with the budget left.
  """
  @spec sync_page(String.t(), String.t(), String.t() | nil, map()) ::
          {:ok, String.t() | :end, map(), %{pushed: integer(), skipped: integer()}}
          | {:error, term()}
  def sync_page(user_id, mode, after_note, budget) do
    with %User{} = user <- Repo.get(User, user_id) || :gone,
         :ok <- RotationGate.check(to_string(user_id)) do
      size = Map.get(budget, :page, @page)
      pg = page(user_id, after_note, size)
      until = if length(pg) == size, do: pg |> List.last() |> elem(0)

      with {:ok, index} <- listing(to_string(user_id), after_note, until, %{}) do
        user
        |> push_groups(
          groups(candidates(mode, pg, index), pg, Map.get(budget, :read_bytes, @read_bytes)),
          index,
          budget
        )
        |> finish_page(until)
      end
    else
      :gone -> {:ok, :end, budget, %{pushed: 0, skipped: 0}}
      {:error, _} = error -> error
    end
  end

  defp finish_page({:ok, :all, budget, got}, nil), do: {:ok, :end, budget, got}
  defp finish_page({:ok, :all, budget, got}, until), do: {:ok, until, budget, got}
  defp finish_page({:ok, {:at, note}, budget, got}, _until), do: {:ok, note, budget, got}
  defp finish_page({:error, _} = error, _until), do: error

  # Read groups in note-id order; stops between groups once the job budget
  # is spent, resuming after the last pushed note.
  defp push_groups(user, groups, index, budget) do
    Enum.reduce_while(groups, {:ok, :all, budget, %{pushed: 0, skipped: 0}}, fn
      {ids, bytes}, {:ok, _, budget, got} ->
        if spent?(budget) and got.pushed + got.skipped > 0 do
          {:halt, {:ok, {:at, last_done(got)}, budget, got}}
        else
          vaults = Map.new(ids, &{&1, index |> Map.get(&1, {nil, 0}) |> elem(0)})

          case Bulk.push(user, ids, vaults) do
            {:ok, counts} ->
              got = %{
                pushed: got.pushed + length(ids) - counts.skipped,
                skipped: got.skipped + counts.skipped,
                last: List.last(ids)
              }

              {:cont, {:ok, :all, %{budget | bytes: budget.bytes - bytes}, got}}

            {:error, _} = error ->
              {:halt, error}
          end
        end
    end)
  end

  defp last_done(%{last: last}), do: last

  defp candidates("full", pg, index),
    do: Enum.sort(Enum.uniq(for({id, n, _b} <- pg, n > 0, do: id) ++ Map.keys(index)))

  # ponytail: counts only, so an equal-count drift (same chunk count, other
  # terms) waits for a version bump or the note's next edit; compare point
  # ids if one shows up.
  defp candidates("diff", pg, index) do
    in_pg = MapSet.new(pg, &elem(&1, 0))

    from_pg =
      for {id, n, _b} <- pg, n != index |> Map.get(id, {nil, 0}) |> elem(1), do: id

    from_index = for {id, _} <- index, not MapSet.member?(in_pg, id), do: id
    Enum.sort(from_pg ++ from_index)
  end

  # Contiguous groups of at most @read_notes notes and @read_bytes content
  # bytes; a note over the byte bound goes alone.
  defp groups(ids, pg, read_bytes) do
    bytes = Map.new(pg, fn {id, _n, b} -> {id, b} end)

    ids
    |> Enum.chunk_while(
      {[], 0},
      fn id, {acc, total} ->
        size = Map.get(bytes, id, 0)

        if acc != [] and (total + size > read_bytes or length(acc) >= @read_notes),
          do: {:cont, {Enum.reverse(acc), total}, {[id], size}},
          else: {:cont, {[id | acc], total + size}}
      end,
      fn
        {[], _} -> {:cont, {[], 0}}
        {acc, total} -> {:cont, {Enum.reverse(acc), total}, {[], 0}}
      end
    )
    |> Enum.reject(&match?({[], _}, &1))
  end

  # kwsearch's notes of the user in (after_note, until]:
  # %{note_id => {vault_id, doc_count}}.
  defp listing(user_id, after_note, until, acc) do
    with {:ok, got} <- Client.notes(user_id, after_note, until, 10_000) do
      acc = Enum.reduce(got, acc, fn {n, v, c}, acc -> Map.put(acc, n, {v, c}) end)

      if length(got) == 10_000,
        do: listing(user_id, got |> List.last() |> elem(0), until, acc),
        else: {:ok, acc}
    end
  end

  # One page of live notes after `after_note`: [{note_id, chunk rows with a
  # point, content bytes}], by id, under the user's tenant.
  defp page(user_id, after_note, size) do
    {:ok, rows} =
      Repo.with_tenant(user_id, fn ->
        from(n in Note,
          left_join: b in NoteBody,
          on: b.note_id == n.id,
          left_join: c in Chunk,
          on: c.note_id == n.id and not is_nil(c.qdrant_point_id),
          where: n.user_id == ^user_id and n.kind == "note" and is_nil(n.deleted_at),
          group_by: [n.id, b.content_bytes],
          order_by: n.id,
          limit: ^size,
          select: {n.id, count(c.qdrant_point_id), coalesce(b.content_bytes, 0)}
        )
        |> then(fn q -> if after_note, do: where(q, [n], n.id > ^after_note), else: q end)
        |> Repo.all()
      end)

    rows
  end
end
