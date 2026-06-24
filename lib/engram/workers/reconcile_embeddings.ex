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

    note_ids =
      Note
      |> join(:inner, [n], v in Vault, on: v.id == n.vault_id and is_nil(v.deleted_at))
      |> where([n], n.kind == "note")
      |> where([n], is_nil(n.deleted_at))
      |> where([n], is_nil(n.embed_hash) or n.embed_hash != n.content_hash)
      # Poison-loop guard: a note that exhausts its EmbedNote attempts gets an
      # embed_retry_after cooldown stamp. Skip it until the cooldown elapses so a
      # permanently-failing note re-bills Voyage at most once per window, not
      # every tick. NULL = no cooldown = eligible now.
      |> where([n], is_nil(n.embed_retry_after) or n.embed_retry_after <= ^now)
      |> order_by([n], asc: n.updated_at)
      |> limit(@batch_size)
      |> select([n], n.id)
      |> Repo.all(skip_tenant_check: true)

    _ =
      if note_ids != [] do
        Logger.debug(
          "reconcile_embeddings: queueing stale notes",
          Engram.Logger.Metadata.with_category(:debug, :search, total_count: length(note_ids))
        )

        Oban.insert_all(Enum.map(note_ids, &EmbedNote.new_debounced/1))
      end

    :ok
  end
end
