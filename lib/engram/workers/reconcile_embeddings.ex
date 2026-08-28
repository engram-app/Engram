defmodule Engram.Workers.ReconcileEmbeddings do
  @moduledoc """
  Oban cron worker: finds notes with stale or missing embeddings and re-queues them.

  Runs every 15 minutes via Oban.Plugins.Cron. Catches any notes that fell through
  the cracks — failed jobs, discarded jobs, config errors, crashes mid-embed.

  A note needs embedding when:
  - embed_hash IS NULL (never embedded)
  - embed_hash != content_hash (content changed since last embed)
  - not soft-deleted
  - embed_retry_after IS NULL or elapsed (not inside a poison cooldown — see
    EmbedNote: a note that exhausts its attempts is parked for a cooldown window
    so it can't re-bill Voyage every tick)

  Uses the partial index idx_notes_embed_pending for fast lookups.
  Batches to avoid flooding the embed queue.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [period: 300, states: :incomplete]

  import Ecto.Query

  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Vaults.Vault
  alias Engram.Workers.EmbedNote

  require Logger

  @batch_size 500

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(15)

  # T3.7 — NO rotation gate needed here. This worker only queries note IDs and
  # enqueues `EmbedNote` jobs — it never decrypts or re-encrypts any payload.
  # The enqueued EmbedNote workers are individually gated via `RotationGate`.
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    # One global query with a global cap. The previous shape loaded EVERY
    # vault and ran one stale-notes query per vault each cron tick —
    # O(total vaults) queries at scale for a worker that only needs ids.
    # Per-vault fairness isn't needed: EmbedNote is uniq-deduped, and the
    # oldest-first order drains any backlog across ticks.
    now = DateTime.utc_now()
    backoff_until = DateTime.add(now, reconcile_backoff_seconds(), :second)

    # Eligible stale notes, oldest-first, capped — kept as a subquery so the
    # whole select-and-stamp is ONE statement (see the UPDATE below).
    eligible =
      from(n in Note, as: :note)
      |> join(:inner, [n], v in Vault, on: v.id == n.vault_id and is_nil(v.deleted_at))
      |> where([n], n.kind == "note")
      |> where([n], is_nil(n.deleted_at))
      # Two ways a note is stale:
      #   1. content changed since it was indexed (or was never indexed)
      #   2. it is indexed but has NO dense vectors, and the user is on a paid
      #      plan — i.e. they upgraded from a keyword-only tier and their
      #      backlog needs the dense leg added
      #
      # (2) is what makes an upgrade self-healing: no hook on the billing path
      # to forget or silently fail, just this cron noticing on its next tick.
      #
      # The subscription join is a SQL-expressible PROXY for
      # `SearchProfile.resolve(user).semantic`, which is a 4-layer resolver and
      # cannot be expressed here. Over-selecting is harmless — `EmbedNote`
      # re-checks the real entitlement and no-ops for a user who is not actually
      # semantic. Under-selecting strands a backlog silently, hence
      # `entitled_statuses/0` rather than a hand-rolled subset — dropping
      # `past_due` stalled the backfill for users who were still paying.
      #
      # The `tier` filter is equally load-bearing: `tier/1` requires BOTH an
      # entitled status AND a paid tier, and `subscriptions.tier` legitimately
      # accepts "free" while `status` DEFAULTS to "trialing". Matching on
      # status alone selects a keyword-only user's notes; EmbedNote's skip
      # clause then returns `:ok` WITHOUT clearing the `embed_retry_after` this
      # worker just stamped, so the note comes back every 30 minutes forever.
      # Over-selecting is not harmless here. What we must NOT
      # do is select every keyword-only note every tick: that is the 15-minute
      # forever-loop this whole column split exists to prevent.
      |> where(
        [n],
        is_nil(n.embed_hash) or n.embed_hash != n.content_hash or
          (is_nil(n.dense_indexed_hash) and
             exists(
               from(s in Engram.Billing.Subscription,
                 where:
                   s.user_id == parent_as(:note).user_id and
                     s.status in ^Engram.Billing.entitled_statuses() and
                     s.tier in ["starter", "pro"],
                 select: 1
               )
             ))
      )
      # Poison-loop guard: a note that exhausts its EmbedNote attempts gets an
      # embed_retry_after cooldown stamp. Skip it until the cooldown elapses so a
      # permanently-failing note re-bills Voyage at most once per window, not
      # every tick. NULL = no cooldown = eligible now. This same filter is what
      # preserves a longer (poison) cooldown from the UPDATE below — a note
      # inside any cooldown isn't selected, so it isn't re-stamped.
      |> where([n], is_nil(n.embed_retry_after) or n.embed_retry_after <= ^now)
      |> order_by([n], asc: n.updated_at)
      |> limit(@batch_size)
      |> select([n], n.id)

    # #897 — crash-independent backoff, done ATOMICALLY. EmbedNote's poison
    # cooldown only fires on a GRACEFUL terminal `{:error, _}` (maybe_mark_poison);
    # an OOM/node kill kills the BEAM mid-embed, so the cooldown is never stamped
    # and this worker would re-enqueue the same poison note every 15 min →
    # self-sustaining crash loop (the 2026-07-03 incident). So instead of a
    # read-only SELECT we UPDATE the eligible notes' embed_retry_after to a short
    # future cooldown and RETURN their ids in one statement — no select→stamp
    # race, and still a single `notes` query regardless of vault count. A
    # successful EmbedNote clears the stamp back to NULL; a graceful terminal
    # failure extends it to the full poison cooldown. The window MUST outlast the
    # 15-min cron interval so a crash-poison note skips at least one tick.
    # `kind == "note"` is redundant with the subquery (which already filters it)
    # but kept explicit so this bulk UPDATE is self-evidently note-scoped — a
    # folder marker can never get an embed cooldown stamped even if the subquery
    # changed. Also satisfies NotesScopeLintTest (kind filter on the from/Note).
    {_count, note_ids} =
      from(n in Note, where: n.kind == "note" and n.id in subquery(eligible))
      |> select([n], n.id)
      |> Repo.update_all([set: [embed_retry_after: backoff_until]], skip_tenant_check: true)

    _ =
      if note_ids != [] do
        # clamp: false — insert_all ignores unique/replace, so the settle
        # ceiling is moot; skip the per-note burst-start SELECT (one per stale
        # note, up to @batch_size, every tick).
        #
        # reject_already_queued/2 is what keeps this worker from being a
        # ratchet. The eligibility query above filters on content/cooldown and
        # NOT on "is a job already pending" — it used to assume `unique` covered
        # that, which insert_all disables. So a note whose job was stuck
        # collected one more job per backoff window: 61,536 jobs for 4,266 notes
        # in dev on 2026-08-25, which is what kept the queue from draining.
        #
        # Backfill priority unconditionally: everything this worker finds is by
        # definition catch-up — a note that fell through, a crash retry, or the
        # tail of a bulk import. None of it has a user waiting on it, so none of
        # it may outrank a live edit.
        fresh = EmbedNote.reject_already_queued(note_ids, EmbedNote.backfill_priority())

        # Report BOTH numbers. `eligible` is what the stale-note query matched;
        # `total_count` is what was actually enqueued. Logging only the former
        # would claim a full batch on every tick while suppressing all of it —
        # unreadable in exactly the backlog incident this guard exists for.
        Logger.debug(
          "reconcile_embeddings: queueing stale notes",
          Engram.Logger.Metadata.with_category(:debug, :search,
            total_count: length(fresh),
            eligible_count: length(note_ids),
            already_queued_count: length(note_ids) - length(fresh)
          )
        )

        Oban.insert_all(
          Enum.map(
            fresh,
            &EmbedNote.new_debounced(&1, clamp: false, priority: EmbedNote.backfill_priority())
          )
        )
      end

    :ok
  end

  # #897 — preemptive cooldown window stamped on every enqueued note (see
  # perform/1). MUST exceed the 15-minute cron interval so a crash-poison note
  # skips at least one tick rather than re-enqueuing immediately. A healthy note
  # is unaffected: its EmbedNote clears the stamp on success, typically within
  # seconds. Env-driven via `EMBED_RECONCILE_BACKOFF_SECONDS` (runtime.exs);
  # default 30 min.
  defp reconcile_backoff_seconds do
    Application.get_env(:engram, :embed_reconcile_backoff_seconds, 1_800)
  end
end
