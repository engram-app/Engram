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
    # Pending runs only: a kick while a sweep is executing queues one more,
    # so notes marked after that sweep's query are not left for the cron.
    unique: [period: 300, states: [:available, :scheduled]]

  import Ecto.Query

  alias Engram.Backfill.TenantScan
  alias Engram.Indexing
  alias Engram.KeywordIndex
  alias Engram.Logger.Metadata
  alias Engram.Notes.Note
  alias Engram.Parsers.Markdown
  alias Engram.Repo
  alias Engram.Vaults.Vault
  alias Engram.Workers.{EmbedNote, ExtractNoteLinks, RebuildStaleNote, RefreshKeywordVectors}

  require Logger

  # Notes stamped and enqueued per statement. Each page drops out of the next
  # page's query (the stamp), so a loop of pages walks the whole backlog.
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
  def perform(%Oban.Job{}) do
    # One query PER TENANT, under a global cap. It cannot be a single
    # cross-tenant statement: `notes` is FORCE RLS, so without a tenant the
    # select-and-stamp below is filtered to zero rows and this whole worker
    # becomes a silent no-op (see the scan comment further down).
    #
    # Still not per-VAULT, which is what this used to be: that ran one
    # stale-notes query per vault per tick, O(total vaults). Per-vault fairness
    # isn't needed — EmbedNote is uniq-deduped and the oldest-first order
    # drains any backlog across ticks.
    now = DateTime.utc_now()
    backoff_until = DateTime.add(now, reconcile_backoff_seconds(), :second)

    # Eligible stale notes, oldest-first, capped — kept as a subquery so the
    # whole select-and-stamp is ONE statement (see the UPDATE below).
    # The SQL proxy for "uncapped and unmetered": a paid, entitled
    # subscription. See the comments on its two uses below.
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
    version_stale = version_stale_dynamic()

    sweep_tenant = fn remaining ->
      eligible =
        from(n in Note, as: :note)
        |> join(:inner, [n], v in Vault, on: v.id == n.vault_id and is_nil(v.deleted_at))
        |> where([n], n.kind == "note")
        |> where([n], is_nil(n.deleted_at))
        # Two ways a note is stale:
        #   1. content changed since it was indexed (or was never indexed)
        #   2. it is indexed but has NO dense vectors, and a dense pass could
        #      add them. That is the backfill for notes indexed sparse-only:
        #      every Free note from before semantic search was every tier's,
        #      and any note a spent embed budget left sparse.
        #
        # (2) is narrowed to notes where the dense pass can actually write
        # something, or it is the forever-loop this column split exists to
        # prevent — EmbedNote clears the backoff stamp below on every pass that
        # ends with no dense hash, so an unwinnable note comes back every tick:
        #
        #   * `exists(chunk)` — the note is INSIDE the indexed-notes cap. An
        #     over-cap note is stamped with no chunk rows and no dense hash, and
        #     can never get one while the cap holds. On Free, with its 2,000
        #     cap, that is most of any large vault. `IndexCap` re-opens those
        #     notes itself when a slot frees (`backfill_freed_slots/1`).
        #   * OR a paid, entitled subscription — the SQL proxy for "uncapped",
        #     so an upgrade backfills the notes that were over the Free cap
        #     (no chunks yet). Self-healing with no hook on the billing path.
        #     `entitled_statuses/0` rather than a hand-rolled subset: dropping
        #     `past_due` stalled the backfill for users who were still paying.
        #     The `tier` filter is load-bearing: `subscriptions.tier` accepts
        #     "free" while `status` DEFAULTS to "trialing", and matching on
        #     status alone would select a capped user's over-cap notes.
        #
        # A note whose embed budget is spent is kept out by the cooldown filter
        # below: EmbedNote parks it with a future `embed_retry_after`.
        |> where(
          ^dynamic(
            [n],
            is_nil(n.embed_hash) or n.embed_hash != n.content_hash or
              ^version_stale or
              (is_nil(n.dense_indexed_hash) and
                 (exists(
                    from(c in Engram.Notes.Chunk,
                      where: c.note_id == parent_as(:note).id,
                      select: 1
                    )
                  ) or
                    exists(paid)))
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
        |> Repo.update_all(set: [embed_retry_after: backoff_until, embed_budget_parked: nil])

      rows
    end

    # Per-tenant, NOT one cross-tenant statement. `notes` carries FORCE ROW
    # LEVEL SECURITY, so with no `app.current_tenant` that UPDATE is FILTERED
    # to zero rows and still reports success: the sweep stamps nothing and
    # enqueues nothing on a database full of stale notes, with a green Oban
    # job. That is the #1349 trap — see `Engram.Backfill.TenantScan`, whose
    # moduledoc describes this exact failure. Inside each tenant's context
    # `eligible` needs no `user_id` filter, because RLS scopes it.
    #
    # Each page is stamped and enqueued in the tenant's transaction, so a
    # note is never stamped without its job.
    counts =
      TenantScan.flat_map_users(fn _user_id ->
        sweep_pages(fn -> sweep_tenant.(@page) end, &enqueue_page/1)
      end)

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

    :ok = sweep_keyword_stale(now, paid)
  end

  # Runs `page` until it returns less than a full page, handing each page to
  # `handle`. Returns [{eligible, queued}] per page.
  defp sweep_pages(page, handle) do
    rows = page.()
    counts = {length(rows), handle.(rows)}

    if length(rows) < @page,
      do: [counts],
      else: [counts | sweep_pages(page, handle)]
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

    # clamp: false — insert_all ignores unique/replace, so the settle ceiling
    # is moot; skip the per-note burst-start SELECT.
    #
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
            clamp: false,
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

  defp version_stale_dynamic do
    chunker = Markdown.chunker_version()
    chunker_stale = dynamic([n], is_nil(n.chunker_version) or n.chunker_version != ^chunker)

    case Indexing.embed_model() do
      # The build cannot name its model: model tracking is off.
      nil ->
        chunker_stale

      model ->
        # `not is_nil` first: on a sparse-only note `dense = content` is NULL,
        # and the keyword sweep negates this predicate, where NOT (NULL)
        # silently drops the row. Every term here must be TRUE or FALSE.
        dynamic(
          [n],
          ^chunker_stale or
            (not is_nil(n.dense_indexed_hash) and not is_nil(n.content_hash) and
               n.dense_indexed_hash == n.content_hash and
               (is_nil(n.embed_model) or n.embed_model != ^model))
        )
    end
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
  defp sweep_keyword_stale(now, paid) do
    version = KeywordIndex.version()
    backoff_until = DateTime.add(now, reconcile_backoff_seconds(), :second)

    page = fn ->
      eligible =
        from(n in Note, as: :note)
        |> join(:inner, [n], v in Vault, on: v.id == n.vault_id and is_nil(v.deleted_at))
        |> where([n], n.kind == "note" and is_nil(n.deleted_at))
        |> where([n], n.embed_hash == n.content_hash)
        |> where([n], is_nil(n.keyword_version) or n.keyword_version != ^version)
        # A version-stale note gets a full rebuild above, which stamps the
        # keyword version itself.
        |> where(^dynamic([n], not (^version_stale_dynamic())))
        |> where(
          [n],
          is_nil(n.embed_retry_after) or n.embed_retry_after <= ^now or
            (n.embed_budget_parked == true and exists(paid))
        )
        |> order_by([n], asc: n.updated_at)
        |> limit(@page)
        |> select([n], n.id)

      # Select-and-stamp in one statement, as the embed sweep does (#897): a
      # note whose resparse keeps failing (a lost Qdrant point 404s
      # `update_vectors`) skips the cooldown window instead of re-entering
      # every tick once its job is discarded. Success stamps
      # `keyword_version`, so a healthy note never comes back.
      {_count, found} =
        from(n in Note, where: n.kind == "note" and n.id in subquery(eligible))
        |> select([n], {n.id, n.user_id})
        |> Repo.update_all(set: [embed_retry_after: backoff_until])

      found
    end

    counts = TenantScan.flat_map_users(fn _user_id -> sweep_pages(page, &enqueue_refresh/1) end)

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
  # more job per note while the queue is behind (the ratchet EmbedNote's
  # `reject_already_queued/2` exists for).
  defp reject_pending([], _worker), do: []

  defp reject_pending(rows, worker) do
    wanted = Enum.map(rows, fn {id, _} -> to_string(id) end)
    worker_name = inspect(worker)

    pending =
      from(j in Oban.Job,
        where: j.worker == ^worker_name,
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        where: fragment("? ->> 'note_id'", j.args) in ^wanted,
        select: fragment("? ->> 'note_id'", j.args)
      )
      |> Repo.all()
      |> MapSet.new()

    Enum.reject(rows, fn {id, _} -> MapSet.member?(pending, to_string(id)) end)
  end

  # #897 — preemptive cooldown window stamped on every enqueued note (see
  # perform/1). MUST exceed the 5-minute cron interval so a crash-poison note
  # skips at least one tick rather than re-enqueuing immediately. A healthy note
  # is unaffected: its EmbedNote clears the stamp on success, typically within
  # seconds. Env-driven via `EMBED_RECONCILE_BACKOFF_SECONDS` (runtime.exs);
  # default 30 min.
  defp reconcile_backoff_seconds do
    Application.get_env(:engram, :embed_reconcile_backoff_seconds, 1_800)
  end
end
