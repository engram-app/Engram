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
    unique: [period: 300, states: [:available, :scheduled, :executing]]

  import Ecto.Query

  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Vaults.Vault
  alias Engram.Workers.EmbedNote

  @batch_size 100

  require Logger

  # T3.7 — NO rotation gate needed here. This worker only queries note IDs and
  # enqueues `EmbedNote` jobs — it never decrypts or re-encrypts any payload.
  # The enqueued EmbedNote workers are individually gated via `RotationGate`.
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    vaults =
      Vault
      |> where([v], is_nil(v.deleted_at))
      |> Repo.all(skip_tenant_check: true)

    Enum.each(vaults, fn vault ->
      note_ids =
        Note
        |> where([n], n.vault_id == ^vault.id)
        |> where([n], is_nil(n.deleted_at))
        |> where([n], is_nil(n.embed_hash) or n.embed_hash != n.content_hash)
        |> order_by([n], asc: n.updated_at)
        |> limit(@batch_size)
        |> select([n], n.id)
        |> Repo.all(skip_tenant_check: true)

      if note_ids != [] do
        Logger.info(
          "reconcile_embeddings: vault=#{vault.id} queueing #{length(note_ids)} stale notes"
        )

        jobs = Enum.map(note_ids, &EmbedNote.new_debounced/1)
        Oban.insert_all(jobs)
      end
    end)

    :ok
  end
end
