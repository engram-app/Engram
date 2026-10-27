defmodule Engram.Jobs do
  @moduledoc """
  Helpers shared by every bulk enqueue site.

  `Oban.insert_all/2` ignores `unique` (bulk uniqueness is an Oban Pro
  feature), so a bulk caller must drop ids that already have a pending job
  itself. Without that, a sweep that runs while its jobs are still queued
  stacks one more job per id per tick: 61,536 pending jobs for 4,266 notes in
  dev on 2026-08-25.
  """

  import Ecto.Query

  alias Engram.Batch
  alias Engram.Repo

  # Ids per lookup query. Postgres plans `args->>'note_id' = ANY($1)` as an
  # index probe up to ~50 ids and flips to a scan of `oban_jobs` above that
  # (measured on a 40k-row table: 0.4-2.8 ms vs 23-31 ms). Ten small probes
  # beat one scan that grows with the backlog.
  @chunk 50

  # The one definition of a job that has not started and so can still absorb
  # a newer edit: an enqueue for the same note joins it instead of adding one.
  # A running job is not in it, because it may already have read the previous
  # content. Module attributes, not parameters, so the queries below stay
  # literal for `oban_jobs_pending_note_id_index`'s partial predicate.
  @pending_states ~w(scheduled available retryable)
  @pending_or_executing ["executing" | @pending_states]

  @doc "Oban states of a job that has not started yet. See `@pending_states`."
  @spec pending_states() :: [String.t()]
  def pending_states, do: @pending_states

  @doc """
  Lower to `priority` every job in `query` ranked worse than it, so a live
  enqueue is not swallowed by a backfill job queued earlier (Oban fetches
  `priority ASC`). A nil `priority` is a no-op. Returns the rows updated.
  """
  @spec promote(Ecto.Queryable.t(), non_neg_integer() | nil) :: non_neg_integer()
  def promote(_query, nil), do: 0

  def promote(query, priority) do
    {count, _} =
      query |> where([j], j.priority > ^priority) |> Repo.update_all(set: [priority: priority])

    count
  end

  @doc """
  `note_ids` minus those with a pending job of `worker`. Order kept.

  Options:
    * `:executing` — whether a running job counts as pending (default true).
      `EmbedNote` passes false: a running embed may be reading content that
      has since changed, so the new job is not a duplicate.
    * `:promote_to` — lower the priority of matching pending jobs ranked
      worse than this, so a live enqueue is not swallowed by a backfill job
      queued earlier at priority 9. Oban fetches `priority ASC`.

  Backed by `oban_jobs_pending_note_id_index` on `((args->>'note_id'),
  worker)`. The key and the states are SQL literals here, not parameters, or
  the planner cannot match the index's expression and partial predicate.

  Not a uniqueness guarantee: two callers racing between this read and their
  inserts can both insert. That is a bounded duplicate, not a ratchet.
  """
  @spec reject_pending(module(), [term()], keyword()) :: [term()]
  def reject_pending(worker, note_ids, opts \\ [])

  def reject_pending(_worker, [], _opts), do: []

  def reject_pending(worker, note_ids, opts) do
    executing? = Keyword.get(opts, :executing, true)
    promote_to = Keyword.get(opts, :promote_to)

    pending =
      note_ids
      |> Enum.map(&to_string/1)
      |> Enum.chunk_every(@chunk)
      |> Enum.flat_map(&pending_ids(pending_query(inspect(worker), &1, executing?), promote_to))
      |> MapSet.new()

    Enum.reject(note_ids, &MapSet.member?(pending, to_string(&1)))
  end

  @doc """
  Inserts `changesets` with `Oban.insert_all/1`, `Engram.Batch.insert_rows/0`
  per statement. Raises on a database error, so a caller inside a transaction
  rolls the jobs back with its other writes. Like `reject_pending/3`'s
  callers, it ignores `unique` (bulk uniqueness is Oban Pro): drop
  already-pending ids first. Returns the number of changesets inserted.
  """
  @spec insert_chunked([Ecto.Changeset.t()]) :: non_neg_integer()
  def insert_chunked(changesets) do
    changesets
    |> Enum.chunk_every(Batch.insert_rows())
    |> Enum.each(&Oban.insert_all/1)

    length(changesets)
  end

  @doc """
  The `note_id` arg of every `worker` job for `vault_id` in one of `states`
  (Oban state names, e.g. `~w(available executing retryable)`), as
  `{ids, capped?}`. Reads at most `limit` ids (default
  `Engram.Batch.quiescence_cap/0`), lowest job id first so the subset is
  stable between calls; a storm backlog is 10k+ ids. `capped?` is true when
  more existed than were returned: the caller must then treat the answer as
  "not settled", because the unread jobs may be owed.
  """
  @spec pending_note_ids_for_vault(module(), String.t(), [String.t()], pos_integer()) ::
          {[String.t()], boolean()}
  def pending_note_ids_for_vault(worker, vault_id, states, limit \\ Batch.quiescence_cap()) do
    ids =
      from(j in Oban.Job,
        where: j.worker == ^inspect(worker),
        where: j.state in ^states,
        where: fragment("? ->> 'vault_id'", j.args) == ^to_string(vault_id),
        order_by: [asc: j.id],
        limit: ^(limit + 1),
        select: fragment("? ->> 'note_id'", j.args)
      )
      |> Repo.all()

    {Enum.take(ids, limit), length(ids) > limit}
  end

  @doc """
  How many `worker` jobs are pending (scheduled, available, executing or
  retryable), counted up to `cap` (the scan stops there).
  """
  @spec pending_count(module(), pos_integer()) :: non_neg_integer()
  def pending_count(worker, cap) do
    jobs =
      from(j in Oban.Job,
        where: j.worker == ^inspect(worker),
        where: j.state in ~w(scheduled available executing retryable),
        limit: ^cap,
        select: j.id
      )

    from(j in subquery(jobs), select: count()) |> Repo.one()
  end

  @doc false
  def pending_query_for_test(worker, wanted, executing?),
    do: pending_query(worker, wanted, executing?)

  defp pending_query(worker, wanted, true) do
    from(j in Oban.Job,
      where: j.worker == ^worker,
      where: j.state in @pending_or_executing,
      where: fragment("? ->> 'note_id'", j.args) in ^wanted
    )
  end

  defp pending_query(worker, wanted, false) do
    from(j in Oban.Job,
      where: j.worker == ^worker,
      where: j.state in @pending_states,
      where: fragment("? ->> 'note_id'", j.args) in ^wanted
    )
  end

  defp pending_ids(query, promote_to) do
    rows = query |> select([j], {fragment("? ->> 'note_id'", j.args), j.priority}) |> Repo.all()

    # The UPDATE only runs when something pending is ranked worse; the common
    # case stays one query.
    _ =
      if promote_to && Enum.any?(rows, fn {_, priority} -> priority > promote_to end),
        do: promote(query, promote_to)

    Enum.map(rows, &elem(&1, 0))
  end
end
