defmodule Engram.Workers.ReconcileEmbeddings do
  @moduledoc """
  Oban cron worker: finds notes with stale or missing embeddings and re-queues them.

  Runs every 5 minutes via Oban.Plugins.Cron, at boot on a queue-running node,
  and whenever something marks notes for re-indexing (`kick/0`). Catches any
  notes that fell through the cracks — failed jobs, discarded jobs, config
  errors, crashes mid-embed — and every index-version rebuild.

  A note needs embedding when:
  - embed_hash IS NULL (never embedded)
  - embed_hash != content_hash (content changed since last embed)
  - not soft-deleted
  - embed_retry_after IS NULL or elapsed (not inside a poison cooldown — see
    EmbedNote: a note that exhausts its attempts is parked for a cooldown window
    so it can't re-bill Voyage every tick)

  Uses the partial index idx_notes_embed_pending for fast lookups. Every stale
  note is queued in one tick, a page at a time; nothing caps a tick. The embed
  queue's concurrency and priority are the throttle: backfill runs at
  priority 9, behind every live edit, and Voyage 429s snooze.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    # One sweep at a time. Two at once stamp the same rows (the stamp's
    # subquery is not re-checked under a row lock) and, on the maintenance
    # pool where the stamp commits before the enqueue, queue them twice. A
    # kick during a sweep is dropped: the running sweep pages until nothing is
    # left, and the 5-min cron catches anything marked after its last page.
    # Period = the 15-min timeout, so a job a killed node left `executing`
    # stops blocking once it could no longer be running.
    unique: [period: 900, states: [:available, :scheduled, :executing]]

  import Ecto.Query

  alias Engram.Backfill.TenantScan
  alias Engram.Billing.LimitKeys
  alias Engram.DataMigrations.IndexVersions
  alias Engram.Logger.Metadata
  alias Engram.Notes.{Chunk, Note}
  alias Engram.Repo
  alias Engram.Workers.{EmbedNote, ExtractNoteLinks, RebuildStaleNote, RefreshKeywordVectors}

  require Logger

  # Notes stamped and enqueued per statement. Each page drops out of the next
  # page's query (the stamp), so a loop of pages walks the whole backlog.
  # Tests pass a smaller `"page"` arg to exercise the loop.
  @page 1_000

  @doc """
  Queues a sweep now. Called where notes are marked for re-indexing (index
  cap changes, orphan repair, plan upgrades) and at boot, so that work starts
  immediately instead of on the next cron tick. Deduplicated while pending.
  """
  def kick, do: Oban.insert(new(%{}))

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(15)

  # T3.7 — NO rotation gate needed here. This worker only queries note IDs and
  # enqueues `EmbedNote` jobs — it never decrypts or re-encrypts any payload.
  # The enqueued EmbedNote workers are individually gated via `RotationGate`.
  @impl Oban.Worker
  def perform(%Oban.Job{args: args, scheduled_at: scheduled_at}) do
    page_size = Map.get(args, "page", @page)

    # Pages through every tenant's stale notes: one pass on the maintenance
    # pool, or one transaction per page per tenant without it (see scan/3).
    # Never per VAULT, which is what this used to be: one stale-notes query
    # per vault per tick, O(total vaults).
    now = DateTime.utc_now()
    backoff_until = DateTime.add(now, reconcile_backoff_seconds(), :second)

    # One page of eligible stale notes, oldest-first, kept as a subquery so
    # the whole select-and-stamp is ONE statement (see the UPDATE below).
    # The SQL proxy for "unmetered": a paid, entitled subscription. Used to
    # let an embed-budget park lapse once the user upgrades (see below).
    # `entitled_statuses/0` rather than a hand-rolled subset: dropping
    # `past_due` stalled the backfill for users who were still paying. The
    # `tier` filter is load-bearing: `subscriptions.tier` accepts "free" while
    # `status` DEFAULTS to "trialing", so matching on status alone would treat
    # a Free user as paying.
    paid =
      from(s in Engram.Billing.Subscription,
        where:
          s.user_id == parent_as(:note).user_id and
            s.status in ^Engram.Billing.entitled_statuses() and
            s.tier in ["starter", "pro"],
        select: 1
      )

    # 3. indexed at its current content by an older chunker, or with dense
    #    vectors from another embed model. #1620 kept this cron off
    #    chunker_version ("never start a mass re-embed"); reversed 2026-10-04:
    #    every index version reaches existing notes automatically, as
    #    unmetered maintenance at backfill priority.
    #
    # Once IndexVersions is done no content-current note is on an old
    # version: skip the version term and the keyword scan (an unindexed
    # per-tenant scan every 5 min). A version bump renames the migration,
    # which reopens both. Except in the daily re-verify hour: a rollback then
    # roll-forward, or a restored soft-deleted vault, puts version-stale notes
    # back after the migration closed, and nothing would reopen it.
    versions_done = IndexVersions.done?() and not daily_reverify?(scheduled_at)
    version_stale = if versions_done, do: dynamic(false), else: IndexVersions.stale_dynamic()

    sweep_tenant = fn repo, remaining ->
      eligible =
        IndexVersions.live_notes()
        # Two ways a note is stale:
        #   1. content changed since it was indexed (or was never indexed)
        #   2. it is indexed but has NO dense vectors. That is the backfill for
        #      notes indexed sparse-only (every Free note from before semantic
        #      search was every tier's, and any note a spent embed budget left
        #      sparse) AND the self-heal for notes the removed search-coverage
        #      cap skipped: those were stamped with no chunk rows and no dense
        #      hash, and this is the only path that re-opens them. Every pass
        #      now either writes dense vectors, stamps a no-chunks note as
        #      dense-complete, or parks it on the embed budget, so (2) no
        #      longer needs narrowing to avoid a forever-loop.
        #
        # A note whose embed budget is spent is kept out by the cooldown filter
        # below: EmbedNote parks it with a future `embed_retry_after`.
        #
        # A floor note (`index_tier` set) has no dense leg by design, so (2)
        # skips it; it would otherwise come back every tick. (1) and the
        # version term still reach it: an edit or a version bump re-floors it,
        # unmetered.
        |> where(
          ^dynamic(
            [n],
            is_nil(n.embed_hash) or n.embed_hash != n.content_hash or
              ^version_stale or (is_nil(n.dense_indexed_hash) and is_nil(n.index_tier))
          )
        )
        # Poison-loop guard: a note that exhausts its EmbedNote attempts gets an
        # embed_retry_after cooldown stamp. Skip it until the cooldown elapses so a
        # permanently-failing note re-bills Voyage at most once per window, not
        # every tick. NULL = no cooldown = eligible now. This same filter is what
        # preserves a longer (poison) cooldown from the UPDATE below — a note
        # inside any cooldown isn't selected, so it isn't re-stamped.
        #
        # Except a BUDGET park for a user who has since upgraded: the budget
        # that parked it no longer applies, and waiting out the 24h would make
        # a paying user's search worse than it needs to be. A poison cooldown
        # (`embed_budget_parked` not true) still holds for everyone.
        |> where(
          [n],
          is_nil(n.embed_retry_after) or n.embed_retry_after <= ^now or
            (n.embed_budget_parked == true and exists(paid))
        )
        |> order_by([n], asc: n.updated_at)
        |> limit(^remaining)
        |> select([n], n.id)

      # #897 — crash-independent backoff, done ATOMICALLY. EmbedNote's poison
      # cooldown only fires on a GRACEFUL terminal `{:error, _}` (maybe_mark_poison);
      # an OOM/node kill kills the BEAM mid-embed, so the cooldown is never stamped
      # and this worker would re-enqueue the same poison note every tick →
      # self-sustaining crash loop (the 2026-07-03 incident). So instead of a
      # read-only SELECT we UPDATE the eligible notes' embed_retry_after to a short
      # future cooldown and RETURN their ids in one statement — no select→stamp
      # race, and still a single `notes` query regardless of vault count. A
      # successful EmbedNote clears the stamp back to NULL; a graceful terminal
      # failure extends it to the full poison cooldown. The window MUST outlast the
      # 5-min cron interval so a crash-poison note skips at least one tick.
      # `kind == "note"` is redundant with the subquery (which already filters it)
      # but kept explicit so this bulk UPDATE is self-evidently note-scoped — a
      # folder marker can never get an embed cooldown stamped even if the subquery
      # changed. Also satisfies NotesScopeLintTest (kind filter on the from/Note).
      {_count, rows} =
        from(n in Note, where: n.kind == "note" and n.id in subquery(eligible))
        # The columns `EmbedNote.version_stale?/1` reads, to route each note.
        |> select([n], %{
          id: n.id,
          user_id: n.user_id,
          embed_hash: n.embed_hash,
          content_hash: n.content_hash,
          dense_indexed_hash: n.dense_indexed_hash,
          chunker_version: n.chunker_version,
          embed_model: n.embed_model
        })
        # Clears the budget-park flag with it: the #897 backoff must hold for
        # this note even for a paying user, or a crash mid-embed re-selects it
        # every tick.
        |> repo.update_all(set: [embed_retry_after: backoff_until, embed_budget_parked: nil])

      rows
    end

    counts = scan(&sweep_tenant.(&1, page_size), page_size, &enqueue_page/1)

    eligible = Enum.sum(Enum.map(counts, &elem(&1, 0)))
    queued = Enum.sum(Enum.map(counts, &elem(&1, 1)))

    # A zero-row sweep logs too. Without it, "nothing is stale" and "the
    # statement was filtered to zero rows by RLS" share one observable —
    # silence plus a green job — and that ambiguity is exactly what hid the
    # unscoped UPDATE this function used to run. `:info`: prod logs at info.
    Logger.info(
      "reconcile_embeddings: swept",
      Metadata.with_category(:info, :search,
        eligible_count: eligible,
        total_count: queued,
        already_queued_count: eligible - queued
      )
    )

    :ok = sweep_over_note_cap(now, paid)
    if versions_done, do: :ok, else: sweep_keyword_stale(now, paid, page_size)
  end

  # Notes rebuilt per tick by `sweep_over_note_cap/2`.
  @recap_batch 100

  # Notes indexed before the per-note cap (or on a plan since downgraded)
  # that hold more chunks than their tier's `note_points_cap`. They go to
  # RebuildStaleNote with `recap: true`, which re-merges them unmetered. One
  # bounded batch per tick: the backlog is a one-off (641 notes in prod on
  # 2026-10-18), and new notes are capped as they are indexed.
  #
  # "More than `cap` chunks" is read as "a chunk at position >= cap": positions
  # are unique per note and start at 0, so a note over the cap always has one,
  # and the (note_id, position) index answers it per note.
  #
  # ponytail: tier defaults only. A per-user or plan-env override of
  # `note_points_cap` is invisible here: a raised cap reselects its notes once
  # per backoff window for a no-op pass (every point reused), a lowered one
  # caps on the next edit. Join the overrides if either ever matters.
  #
  # Dense notes only: a sparse-only note reaches the dense backfill (term 2 of
  # the main sweep), whose pass caps it.
  defp sweep_over_note_cap(now, paid) do
    # The flag `Billing.effective_limit/2` reads: off (self-host), no cap.
    if Application.get_env(:engram, :limits_enforced, true) do
      free_cap = LimitKeys.default_for(:note_points_cap, :free)
      paid_cap = LimitKeys.default_for(:note_points_cap, :starter)
      backoff_until = DateTime.add(now, reconcile_backoff_seconds(), :second)

      over = fn cap ->
        from(c in Chunk,
          where: c.note_id == parent_as(:note).id and c.position >= ^cap,
          select: 1
        )
      end

      page = fn repo, limit ->
        eligible =
          IndexVersions.content_current_notes()
          |> where([n], n.dense_indexed_hash == n.content_hash and is_nil(n.index_tier))
          |> where([n], is_nil(n.embed_retry_after) or n.embed_retry_after <= ^now)
          |> where(
            [n],
            exists(over.(free_cap)) and (not exists(paid) or exists(over.(paid_cap)))
          )
          |> order_by([n], asc: n.updated_at)
          |> limit(^limit)
          |> select([n], n.id)

        {_count, found} =
          from(n in Note, where: n.kind == "note" and n.id in subquery(eligible))
          |> select([n], {n.id, n.user_id})
          |> repo.update_all(set: [embed_retry_after: backoff_until])

        found
      end

      rows =
        case Repo.maintenance() do
          Repo ->
            Enum.reduce_while(TenantScan.user_ids(), [], fn user_id, acc ->
              case @recap_batch - length(acc) do
                0 ->
                  {:halt, acc}

                left ->
                  {:ok, found} = Repo.with_tenant(user_id, fn -> page.(Repo, left) end)
                  {:cont, acc ++ found}
              end
            end)

          maintenance ->
            page.(maintenance, @recap_batch)
        end

      fresh = reject_pending(rows, RebuildStaleNote)

      _ =
        Oban.insert_all(
          Enum.map(fresh, fn {note_id, user_id} ->
            RebuildStaleNote.new(%{note_id: to_string(note_id), user_id: user_id, recap: true},
              priority: EmbedNote.backfill_priority()
            )
          end)
        )

      Logger.info(
        "reconcile_embeddings: swept notes over the per-note cap",
        Metadata.with_category(:info, :search,
          eligible_count: length(rows),
          total_count: length(fresh)
        )
      )
    end

    :ok
  end

  # The hour a day (04:00-04:59 UTC, twelve "2-59/5" ticks) that re-checks
  # index versions after IndexVersions is done. A whole hour, not one tick: the
  # unique window can dedupe any single tick, and a skipped tick must not skip
  # the day. A pure function of the job's time: no extra cron entry, no state.
  # A kick landing in the hour counts too.
  defp daily_reverify?(%DateTime{hour: 4}), do: true
  defp daily_reverify?(_scheduled_at), do: false

  # Runs `sweep.(repo)` over every tenant: once on the maintenance pool
  # (which sees every tenant) where one is configured, as prod does; else
  # once per user inside that user's tenant.
  #
  # Never one cross-tenant statement on the app pool. `notes` carries FORCE
  # ROW LEVEL SECURITY, so with no `app.current_tenant` that UPDATE is
  # FILTERED to zero rows and still reports success: the sweep stamps nothing
  # and enqueues nothing on a database full of stale notes, with a green Oban
  # job. That is the #1349 trap — see `Engram.Backfill.TenantScan`. Inside
  # each tenant's context `eligible` needs no `user_id` filter: RLS scopes it.
  # On the per-user path each page is stamped and enqueued in the tenant's
  # transaction; on the maintenance path the stamp commits first, and a lost
  # enqueue costs that note one cooldown window.
  defp scan(page, page_size, handle) do
    case Repo.maintenance() do
      Repo ->
        # One transaction PER PAGE, inside the user's tenant: stamp and
        # enqueue stay atomic, and no transaction holds a whole backlog. One
        # per user ran past the 15 s checkout deadline on a large backlog,
        # rolled back, and stalled every user after it on every tick.
        Enum.flat_map(TenantScan.user_ids(), fn user_id ->
          sweep_pages(page_size, fn ->
            {:ok, counts} =
              Repo.with_tenant(user_id, fn -> page_counts(page.(Repo), handle) end)

            counts
          end)
        end)

      maintenance ->
        sweep_pages(page_size, fn -> page_counts(page.(maintenance), handle) end)
    end
  end

  defp page_counts(rows, handle), do: {length(rows), handle.(rows)}

  # Runs `page` (which returns {rows_found, jobs_queued}) until a page comes
  # back short. Returns the counts of every page.
  defp sweep_pages(page_size, page) do
    {found, _queued} = counts = page.()

    if found < page_size,
      do: [counts],
      else: [counts | sweep_pages(page_size, page)]
  end

  # A version rebuild (content current, older chunker or embed model) goes to
  # RebuildStaleNote, a worker the previous release lacks, so a rolling
  # deploy's old nodes cannot run it metered. Everything else is EmbedNote's.
  # Returns how many jobs were queued.
  defp enqueue_page([]), do: 0

  defp enqueue_page(rows) do
    {rebuild_rows, embed_rows} = Enum.split_with(rows, &version_rebuild?/1)
    rebuilt = enqueue_rebuilds(rebuild_rows)
    user_by_note = Map.new(embed_rows, &{&1.id, &1.user_id})

    # reject_already_queued/2 is what keeps this worker from being a ratchet.
    # The eligibility query filters on content/cooldown and NOT on "is a job
    # already pending" — insert_all disables `unique`. So a note whose job was
    # stuck collected one more job per backoff window: 61,536 jobs for 4,266
    # notes in dev on 2026-08-25, which is what kept the queue from draining.
    #
    # Backfill priority unconditionally: everything this worker finds is
    # catch-up with no user waiting on it, so none of it may outrank a live
    # edit.
    fresh =
      embed_rows
      |> Enum.map(& &1.id)
      |> EmbedNote.reject_already_queued(EmbedNote.backfill_priority())

    _ =
      Oban.insert_all(
        Enum.map(
          fresh,
          &EmbedNote.new_debounced(&1, Map.fetch!(user_by_note, &1),
            priority: EmbedNote.backfill_priority()
          )
        )
      )

    # Backstop for the link graph. ExtractNoteLinks is the only note_links
    # writer and is enqueued beside EmbedNote after the write commits, so a
    # note whose embed enqueue was lost most likely lost its link extraction
    # too. Only for notes whose CONTENT changed: a dense-only backfill or a
    # version rebuild leaves the links as they are.
    queued = MapSet.new(fresh)

    relink =
      for r <- embed_rows,
          MapSet.member?(queued, r.id),
          r.embed_hash != r.content_hash,
          do: r.id

    _ =
      Oban.insert_all(
        Enum.map(relink, &ExtractNoteLinks.new_debounced(&1, Map.fetch!(user_by_note, &1)))
      )

    rebuilt + length(fresh)
  end

  defp version_rebuild?(%{embed_hash: hash, content_hash: hash} = row) when hash != nil,
    do: EmbedNote.version_stale?(struct(Note, row))

  defp version_rebuild?(_row), do: false

  defp enqueue_rebuilds([]), do: 0

  defp enqueue_rebuilds(rows) do
    fresh = reject_pending(Enum.map(rows, &{&1.id, &1.user_id}), RebuildStaleNote)

    _ =
      Oban.insert_all(
        Enum.map(fresh, fn {note_id, user_id} ->
          RebuildStaleNote.new(%{note_id: to_string(note_id), user_id: user_id},
            priority: EmbedNote.backfill_priority()
          )
        end)
      )

    length(fresh)
  end

  # Notes indexed at their current content whose keyword vectors predate
  # `KeywordIndex.version/0`: a keyword-encoding change (tokenizer, stemmer,
  # what text is encoded) reaches them here with no operator step, on SaaS and
  # every self-host install. They go to RefreshKeywordVectors, which rewrites only the
  # sparse vectors and never calls the embedder. NOT to EmbedNote: most of
  # these notes also carry a stale `chunker_version`, and EmbedNote would
  # answer that with a full re-embed (see the chunker test in this module's
  # suite).
  #
  # Content-stale notes are left to the sweep above: EmbedNote's full pass
  # stamps the keyword version itself. Same cooldown filter and stamp as above.
  #
  # ponytail: `keyword_version` is unindexed, so this scans each tenant's live
  # notes every tick. Fine at thousands of notes per tenant; add a partial
  # index on (user_id) WHERE keyword_version IS DISTINCT FROM <current> if a
  # tenant reaches hundreds of thousands.
  defp sweep_keyword_stale(now, paid, page_size) do
    backoff_until = DateTime.add(now, reconcile_backoff_seconds(), :second)

    page = fn repo ->
      eligible =
        IndexVersions.content_current_notes()
        |> where(^IndexVersions.keyword_stale_dynamic())
        # A version-stale note gets a full rebuild above, which stamps the
        # keyword version itself.
        |> where(^dynamic([n], not (^IndexVersions.stale_dynamic())))
        |> where(
          [n],
          is_nil(n.embed_retry_after) or n.embed_retry_after <= ^now or
            (n.embed_budget_parked == true and exists(paid))
        )
        |> order_by([n], asc: n.updated_at)
        |> limit(^page_size)
        |> select([n], n.id)

      # Select-and-stamp in one statement, as the embed sweep does (#897): a
      # note whose resparse keeps failing (a lost Qdrant point 404s
      # `update_vectors`) skips the cooldown window instead of re-entering
      # every tick once its job is discarded. Success stamps
      # `keyword_version`, so a healthy note never comes back.
      {_count, found} =
        from(n in Note, where: n.kind == "note" and n.id in subquery(eligible))
        |> select([n], {n.id, n.user_id})
        # Clears the budget-park flag too, as the embed sweep's stamp does: a
        # parked note of a paying user stays eligible through the cooldown
        # filter otherwise, and every page would return it again.
        |> repo.update_all(set: [embed_retry_after: backoff_until, embed_budget_parked: nil])

      found
    end

    counts = scan(page, page_size, &enqueue_refresh/1)

    Logger.info(
      "reconcile_embeddings: swept keyword-stale notes",
      Metadata.with_category(:info, :search,
        eligible_count: Enum.sum(Enum.map(counts, &elem(&1, 0))),
        total_count: Enum.sum(Enum.map(counts, &elem(&1, 1)))
      )
    )

    :ok
  end

  defp enqueue_refresh(rows) do
    fresh = reject_pending(rows, RefreshKeywordVectors)

    _ =
      Oban.insert_all(
        Enum.map(fresh, fn {note_id, user_id} ->
          RefreshKeywordVectors.new(%{note_id: to_string(note_id), user_id: user_id},
            priority: EmbedNote.backfill_priority()
          )
        end)
      )

    length(fresh)
  end

  # insert_all ignores `unique`, so without this every tick would stack one
  # more job per note while the queue is behind (the ratchet).
  defp reject_pending(rows, worker) do
    fresh =
      rows
      |> Enum.map(&elem(&1, 0))
      |> then(&Engram.Jobs.reject_pending(worker, &1))
      |> MapSet.new()

    Enum.filter(rows, &MapSet.member?(fresh, elem(&1, 0)))
  end

  # #897 — preemptive cooldown window stamped on every enqueued note (see
  # perform/1). MUST exceed the 5-minute cron interval so a crash-poison note
  # skips at least one tick rather than re-enqueuing immediately. A healthy note
  # is unaffected: its EmbedNote clears the stamp on success, typically within
  # seconds. Env-driven via `EMBED_RECONCILE_BACKOFF_SECONDS` (runtime.exs);
  # default 30 min.
  # Floored at 6 min, past the cron interval: at or below `now` the stamp no
  # longer removes a note from the next page's query, and the page loop
  # never ends.
  defp reconcile_backoff_seconds do
    max(Application.get_env(:engram, :embed_reconcile_backoff_seconds, 1_800), 360)
  end
end
