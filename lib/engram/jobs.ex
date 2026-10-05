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

  alias Engram.Repo

  # Ids per lookup query. Postgres plans `args->>'note_id' = ANY($1)` as an
  # index probe up to ~50 ids and flips to a scan of `oban_jobs` above that
  # (measured on a 40k-row table: 0.4-2.8 ms vs 23-31 ms). Ten small probes
  # beat one scan that grows with the backlog.
  @chunk 50

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

  @doc false
  def pending_query_for_test(worker, wanted, executing?),
    do: pending_query(worker, wanted, executing?)

  defp pending_query(worker, wanted, true) do
    from(j in Oban.Job,
      where: j.worker == ^worker,
      where: j.state in ~w(scheduled available executing retryable),
      where: fragment("? ->> 'note_id'", j.args) in ^wanted
    )
  end

  defp pending_query(worker, wanted, false) do
    from(j in Oban.Job,
      where: j.worker == ^worker,
      where: j.state in ~w(scheduled available retryable),
      where: fragment("? ->> 'note_id'", j.args) in ^wanted
    )
  end

  defp pending_ids(query, promote_to) do
    rows = query |> select([j], {fragment("? ->> 'note_id'", j.args), j.priority}) |> Repo.all()

    # The UPDATE only runs when something pending is ranked worse; the common
    # case stays one query.
    if promote_to && Enum.any?(rows, fn {_, priority} -> priority > promote_to end) do
      query
      |> where([j], j.priority > ^promote_to)
      |> Repo.update_all(set: [priority: promote_to])
    end

    Enum.map(rows, &elem(&1, 0))
  end
end
