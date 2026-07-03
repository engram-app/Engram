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
      Note
      |> join(:inner, [n], v in Vault, on: v.id == n.vault_id and is_nil(v.deleted_at))
      |> where([n], n.kind == "note")
      |> where([n], is_nil(n.deleted_at))
      |> where([n], is_nil(n.embed_hash) or n.embed_hash != n.content_hash)
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
        Logger.debug(
          "reconcile_embeddings: queueing stale notes",
          Engram.Logger.Metadata.with_category(:debug, :search, total_count: length(note_ids))
        )

        # clamp: false — insert_all ignores unique/replace, so the settle
        # ceiling is moot; skip the per-note burst-start SELECT (one per stale
        # note, up to @batch_size, every tick).
        Oban.insert_all(Enum.map(note_ids, &EmbedNote.new_debounced(&1, clamp: false)))
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
