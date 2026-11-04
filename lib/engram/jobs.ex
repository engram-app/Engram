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

  # ---------------------------------------------------------------------------
  # Job options: the ONE home of every `unique:` policy, the oban_jobs
  # retention and reindex settings, and suspended-job handling. Workers and
  # enqueue sites call `unique/2`; JobsOptionsSourceTest fails on an inline
  # `unique:` anywhere else in lib/.
  # ---------------------------------------------------------------------------

  # Completed, cancelled and discarded jobs are deleted this long after they
  # finish. Every retained row is read by the queue polls and unique checks;
  # ObanRetentionTest holds every unique period below this unless a table
  # dedupes it. Oban's Pruner never deletes `suspended`: see `suspend_copy/2`.
  @retention_seconds 24 * 3600

  # EmbedNote's debounced dedup: every incomplete state but `executing`. A
  # running pass may already have read the previous content, so a newer edit
  # needs its own job (the rule `reject_pending/3` applies to bulk enqueues).
  # The two passes are safe together: `Indexing` re-checks `content_hash`
  # under `FOR UPDATE` and the stale one rolls back `:superseded` (#2294).
  @embed_pending Enum.map(@pending_states, &String.to_atom/1)

  # Every unique policy, by worker (its `use Oban.Worker` default) or by
  # `{worker, call_site}`. `unique/2` adds `:queue` to a narrowed `fields:`.
  @unique %{
    Engram.Billing.Workers.OverrideExpirySweep => [period: 60, fields: [:worker]],
    Engram.Billing.Workers.PaddleReconcile => [period: 60, fields: [:worker, :args]],
    Engram.Workers.AccountExport => [fields: [:args], period: :infinity],
    Engram.Workers.BackfillLinkKeys => [
      keys: [:user_id],
      period: :infinity,
      states: [:available, :scheduled, :retryable]
    ],
    Engram.Workers.BookkeepingCanary => [period: 3000, states: :incomplete],
    Engram.Workers.BookkeepingDrain => [period: 600, states: :incomplete],
    Engram.Workers.CancelReasonMarker => [
      keys: [:user_id, :effective_at],
      states: [:available, :scheduled],
      period: :infinity
    ],
    Engram.Workers.CheckpointNote => [keys: [:note_id], states: :incomplete],
    Engram.Workers.CleanupDeviceAuthWorker => [
      period: 600,
      states: [:available, :scheduled, :executing]
    ],
    Engram.Workers.ConnectionCreated => [keys: [:user_id, :client_id], period: 30 * 24 * 3600],
    Engram.Workers.DailySnapshot => [period: 3000],
    Engram.Workers.DataMigrationsRunner => [period: 3000, states: :incomplete],
    Engram.Workers.DrainStrandedTails => [period: 600, states: :incomplete],
    Engram.Workers.EmbedNote => [period: 60, keys: [:note_id], states: :incomplete],
    # Period is the caller's settle window (`EmbedNote.job/3`).
    {Engram.Workers.EmbedNote, :debounced} => [keys: [:note_id], states: @embed_pending],
    {Engram.Workers.ExtractNoteLinks, :debounced} => [
      period: 60,
      keys: [:note_id],
      states: [:available, :scheduled]
    ],
    {Engram.Workers.FinalizeRevision, :debounced} => [
      period: 60,
      keys: [:note_id],
      states: [:available, :scheduled, :retryable]
    ],
    Engram.Workers.HealKeyAliases => [
      keys: [:user_id],
      period: :infinity,
      states: [:available, :scheduled, :retryable]
    ],
    Engram.Workers.MigrateUserProvider => [
      keys: [:user_id, :target_provider],
      states: :incomplete
    ],
    {Engram.Workers.PersonOriginSync, :backfill_head} => [
      fields: [:worker, :args],
      keys: [:backfill],
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable]
    ],
    {Engram.Workers.PersonOriginSync, :user} => [period: 300, fields: [:worker, :args]],
    {Engram.Workers.PersonOriginSync, :chain_next} => [
      fields: [:worker, :args],
      keys: [:chain, :after],
      period: 7200,
      states: :all
    ],
    Engram.Workers.ProjectVaultIndex => [keys: [:vault_id], states: :incomplete],
    # Pending only: see `CrdtIndexPersistence` (a running pass already read
    # the older snapshot).
    {Engram.Workers.ProjectVaultIndex, :pending} => [
      keys: [:vault_id],
      states: [:available, :scheduled, :retryable]
    ],
    Engram.Workers.RebuildDryRun => [
      period: :infinity,
      keys: [:user_id],
      states: [:available, :scheduled, :executing, :retryable]
    ],
    Engram.Workers.RebuildStaleNote => [
      period: 3600,
      keys: [:note_id],
      states: [:available, :scheduled]
    ],
    Engram.Workers.ReconcileAttachmentBlobs => [keys: [:vault_id], period: 600],
    Engram.Workers.ReconcileEmbeddings => [
      fields: [:worker, :queue],
      period: 900,
      states: [:available, :scheduled, :retryable]
    ],
    Engram.Workers.ReconcileNotePayloads => [
      keys: [:user_id],
      period: :infinity,
      states: [:available, :scheduled, :retryable]
    ],
    Engram.Workers.ReencodeEnvelopes => [
      keys: [:user_id],
      period: :infinity,
      states: [:available, :scheduled, :retryable]
    ],
    Engram.Workers.RefreshKeywordVectors => [
      period: 3600,
      keys: [:note_id],
      states: [:available, :scheduled]
    ],
    Engram.Workers.RepathNoteIndex => [
      period: 120,
      keys: [:note_id, :old_path_hmac],
      states: :incomplete
    ],
    # Period is the caller's repair window (`ExtractNoteLinks`).
    {Engram.Workers.RewriteNoteLinks, :repair} => [
      keys: [:target_id, :old_basename_hmac],
      states: [:available, :scheduled]
    ],
    Engram.Workers.RotateUserDek => [keys: [:user_id], states: :incomplete],
    Engram.Workers.RotateUserMasterKey => [keys: [:user_id, :target_version], states: :incomplete],
    Engram.Workers.RotationTextGuard => [
      keys: [:user_id, :dek_version],
      period: :infinity,
      states: [:available, :scheduled, :retryable]
    ],
    Engram.Workers.WarmCrdtHeads => [period: 3000, states: :incomplete],
    # Unique among held copies only: the running original is `executing` and
    # must not block its own hold, but a re-run of it (Lifeline rescue, a
    # retry of the completed original) must not hold a second copy, or both
    # are released at once (two DEK rotations overlapping).
    :suspended_copy => [period: :infinity, states: [:suspended]]
  }

  @doc """
  The `unique:` option for `key` (a worker, `{worker, call_site}`, or
  `:none` for an insert that must never dedup), with `overrides` (a
  caller's runtime `period`) merged in.

  A narrowed `fields:` always gets `:queue`. Oban's check is `WHERE state IN
  (..) AND inserted_at >= .. AND <one predicate per field>`, and the only
  btree it can use is `(state, queue, ...)`: without `queue` it seq-scans
  oban_jobs (3.8 s per check in prod on 2026-11-03, planner cost 11,016
  against 904 with it). A worker runs on one queue, so dedup is unchanged.
  """
  @spec unique(term(), keyword()) :: keyword() | false
  def unique(key, overrides \\ [])
  def unique(:none, []), do: false

  def unique(key, overrides) do
    opts = @unique |> Map.fetch!(key) |> Keyword.merge(overrides)

    case Keyword.fetch(opts, :fields) do
      {:ok, fields} ->
        if :queue in fields, do: opts, else: Keyword.put(opts, :fields, fields ++ [:queue])

      :error ->
        opts
    end
  end

  @doc "Every unique policy key (ObanRetentionTest walks them)."
  @spec unique_keys() :: [term()]
  def unique_keys, do: Map.keys(@unique)

  @doc "Seconds a finished job is kept before the Pruner deletes it."
  # No `@spec`: the body is a constant, so pos_integer() is a dialyzer
  # `contract_supertype` (as `Rebuild.build_versions/0`).
  def retention_seconds, do: @retention_seconds

  @doc """
  `Oban.Reindexer` options. oban_jobs is a queue table: every row is
  pruned within a day and VACUUM never shrinks a btree or GIN (prod
  2026-11-03: 73 MB of index for 17 MB of rows). `REINDEX INDEX
  CONCURRENTLY` blocks no insert, fetch or update.

    * `indexes`: every index oban_jobs has (ObanReindexerTest checks the
      migrated schema). Oban's default names `oban_jobs_meta_index`, which
      we dropped, so it would fail every run.
    * `schedule`: daily 10:37 UTC (weekly was too rare for a table that
      turns over every day), inside the 10:00-11:15 window, on a
      minute no cron uses (ObanReindexerTest).
    * `timeout`: per statement; Oban's 15 s default is short for the GIN.

  Needs MAINTAIN on oban_jobs for the runtime role (migration
  20261103200000). A run cut short leaves an invalid `*_ccnew` copy only the
  table owner can drop: `docs/context/oban-jobs-reindex.md`.
  """
  @spec reindexer() :: keyword()
  def reindexer do
    [
      schedule: "37 10 * * *",
      timeout: :timer.minutes(10),
      indexes: ~w(
        oban_jobs_pkey
        oban_jobs_args_index
        oban_jobs_state_queue_priority_scheduled_at_id_index
        oban_jobs_pending_note_id_index
        oban_jobs_state_cancelled_at_index
        oban_jobs_state_discarded_at_index
        oban_jobs_embed_note_note_id_index
        oban_jobs_rewrite_note_links_old_basename_hmac_index
      )
    ]
  end

  @doc """
  `conf` (the `:engram, Oban` env) with the oban_jobs table plugins added:
  the Pruner (`retention_seconds/0`) and the Reindexer (`reindexer/0`).
  A node with `plugins: false` (web) gets neither.
  """
  @spec oban_config(keyword()) :: keyword()
  def oban_config(conf) do
    case Keyword.get(conf, :plugins) do
      plugins when is_list(plugins) ->
        table_plugins = [
          {Oban.Plugins.Pruner, max_age: @retention_seconds},
          {Oban.Reindexer, reindexer()}
        ]

        Keyword.put(conf, :plugins, plugins ++ table_plugins)

      _false ->
        conf
    end
  end

  @doc """
  Parks a copy of `job` as `suspended`, tagged `meta.held = tag`, and returns
  `:ok`. Oban never stages or fetches a suspended job, so it writes nothing
  while it waits (a snooze rewrites the row every wake, a non-HOT UPDATE).
  `release_suspended/1` frees it. Not pruned: a held job is real work, so the
  holder must release it (the count is
  `engram_prom_ex_oban_queue_length_count{state="suspended"}`).
  """
  @spec suspend_copy(Oban.Job.t(), String.t()) :: :ok
  def suspend_copy(%Oban.Job{} = job, tag) do
    changeset =
      Oban.Job.new(job.args,
        worker: job.worker,
        queue: job.queue,
        priority: job.priority,
        max_attempts: job.max_attempts,
        meta: Map.put(job.meta || %{}, "held", tag),
        tags: job.tags || [],
        unique: unique(:suspended_copy)
      )

    # `state` is a permitted field but not in `Oban.Job.new/2`'s option
    # typespec, so it is set on the changeset (dialyzer read the option as
    # a call that never returns).
    _job = Oban.insert!(Ecto.Changeset.put_change(changeset, :state, "suspended"))
    :ok
  end

  @doc "Deletes the `tag` copy of `job` (same worker and args) `suspend_copy/2` parked."
  @spec drop_suspended(Oban.Job.t(), String.t()) :: non_neg_integer()
  def drop_suspended(%Oban.Job{worker: worker, args: args}, tag) do
    {count, _} =
      from(j in suspended_query(tag), where: j.worker == ^worker and j.args == ^args)
      |> Repo.delete_all()

    count
  end

  # Held copies one release makes available. Prod had 801 held repaths: all
  # at once is a burst of Qdrant payload writes and DB updates. The hourly
  # release drains the rest over the next runs.
  @release_per_run 200

  @doc """
  Makes up to `limit` `tag` copies available now, oldest first. Returns how
  many. The holder's cron calls it each run until it returns 0.
  """
  @spec release_suspended(String.t(), pos_integer()) :: non_neg_integer()
  def release_suspended(tag, limit \\ @release_per_run) do
    ids = from(j in suspended_query(tag), order_by: j.id, limit: ^limit, select: j.id)

    # The outer query re-checks `suspended`: Postgres re-evaluates only the
    # outer predicate on a row a concurrent release just changed, so two
    # overlapping releases never free (and run) one job twice.
    {count, _} =
      from(j in suspended_query(tag), where: j.id in subquery(ids))
      |> Repo.update_all(set: [state: "available", scheduled_at: DateTime.utc_now()])

    count
  end

  defp suspended_query(tag),
    do:
      from(j in Oban.Job,
        where: j.state == "suspended" and fragment("?->>'held' = ?", j.meta, ^tag)
      )

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

  @doc """
  The one capped exponential wait: `base` doubled `step` times, capped at
  `cap`, plus up to a `jitter` share more (`Oban.Backoff.jitter/2`, only
  ever adding). Used for Oban backoffs and growing snoozes alike.
  """
  @spec capped_backoff(pos_integer(), non_neg_integer(), pos_integer(), float()) ::
          pos_integer()
  def capped_backoff(base, step, cap, jitter \\ 0.0) do
    # Past 2^32 every base is over any cap; bound it before Integer.pow.
    (base * Integer.pow(2, min(step, 32)))
    |> min(cap)
    |> Oban.Backoff.jitter(mode: :inc, mult: jitter)
    # Oban specs jitter/2 as number(); it returns an integer for an integer
    # input, so this is a no-op that keeps our pos_integer() contract honest.
    |> trunc()
  end
end
