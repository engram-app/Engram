defmodule Engram.Workers.ReconcileEmbeddings do
  @moduledoc """
  Oban cron worker: finds notes with stale or missing embeddings and re-queues them.

  Runs every 15 minutes via Oban.Plugins.Cron. Catches any notes that fell through
  the cracks — failed jobs, discarded jobs, config errors, crashes mid-embed.

  A note needs embedding when:
  - embed_hash IS NULL (never embedded)
  - embed_hash != content_hash (content changed since last embed)
  - not soft-deleted

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
    note_ids =
      Note
      |> join(:inner, [n], v in Vault, on: v.id == n.vault_id and is_nil(v.deleted_at))
      |> where([n], n.kind == "note")
      |> where([n], is_nil(n.deleted_at))
      |> where([n], is_nil(n.embed_hash) or n.embed_hash != n.content_hash)
      |> order_by([n], asc: n.updated_at)
      |> limit(@batch_size)
      |> select([n], n.id)
      |> Repo.all(skip_tenant_check: true)

    _ =
      if note_ids != [] do
        Logger.info("reconcile_embeddings: queueing #{length(note_ids)} stale notes")
        Oban.insert_all(Enum.map(note_ids, &EmbedNote.new_debounced/1))
      end

    :ok
  end
end
