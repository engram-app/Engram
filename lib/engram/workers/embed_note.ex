defmodule Engram.Workers.EmbedNote do
  @moduledoc """
  Oban worker: embeds a note and upserts to Qdrant.

  Debounce: 5-second scheduled_at delay, replaced on re-insert so rapid edits
  trigger only one Voyage API call.

  Dedup: unique per note_id in available/scheduled states, 60-second window.

  Idempotency: skips embedding when embed_hash already matches content_hash
  (content hasn't changed since last successful embed). On success, sets
  embed_hash = content_hash using an optimistic lock — if content changed
  mid-embed, the update is a no-op and the next job picks up the new version.
  """

  use Oban.Worker,
    queue: :embed,
    max_attempts: 5,
    unique: [
      period: 60,
      keys: [:note_id],
      states: [:available, :scheduled]
    ]

  require Logger

  import Ecto.Query

  alias Engram.Accounts
  alias Engram.Crypto
  alias Engram.Crypto.RotationGate
  alias Engram.Indexing
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Vaults.Vault

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    note_id = args["note_id"]
    # T3.2 — `old_path_hmac` is a base64-encoded HMAC, never plaintext path.
    old_path_hmac_b64 = args["old_path_hmac"]

    # skip_tenant_check: trusted internal worker — queries already scoped to note_id/user_id
    case Repo.get(Note, note_id, skip_tenant_check: true) do
      nil ->
        {:discard, "note #{note_id} not found"}

      %Note{deleted_at: deleted_at} when not is_nil(deleted_at) ->
        {:discard, "note #{note_id} is soft-deleted"}

      %Note{content_hash: hash, embed_hash: hash}
      when not is_nil(hash) and is_nil(old_path_hmac_b64) ->
        # Already embedded this exact content and no rename pending — skip
        :ok

      note ->
        # T3.7 — gate writes during DEK rotation. The worker may have been
        # enqueued before the lock was acquired; re-check the live row.
        case RotationGate.check(note.user_id) do
          {:error, :rotation_in_progress} ->
            :telemetry.execute(
              [:engram, :crypto, :rotate, :dek, :gate_blocked],
              %{count: 1},
              %{gate_path: :worker, op: :embed_note}
            )

            {:snooze, 60}

          {:error, :user_not_found} ->
            {:discard, :user_deleted}

          :ok ->
            run_embed(note, old_path_hmac_b64)
        end
    end
  end

  defp run_embed(note, old_path_hmac_b64) do
    user = Accounts.get_user!(note.user_id)

    # Load vault up front so we can drive both the decrypt path (future) and
    # the index call. skip_tenant_check: trusted internal worker.
    # Missing vault means the note is orphaned — nothing to index, discard.
    case Repo.get(Vault, note.vault_id, skip_tenant_check: true) do
      nil ->
        {:discard, "vault #{note.vault_id} not found for note #{note.id}"}

      %Vault{} = vault ->
        case Crypto.maybe_decrypt_note_fields(note, user) do
          {:ok, decrypted_note} ->
            # If renamed, clean up old path's Qdrant points before re-indexing
            if old_path_hmac_b64 do
              Indexing.delete_points_by_path_hmac(decrypted_note, old_path_hmac_b64)
            end

            case Indexing.index_note(decrypted_note, vault) do
              {:ok, _count} ->
                stamp_embed_hash(note)
                :ok

              {:error, reason} ->
                {:error, reason}
            end

          {:error, reason} ->
            Logger.error(
              "EmbedNote decrypt failed: user_id=#{note.user_id} note_id=#{note.id} reason=#{inspect(reason)}"
            )

            {:error, reason}
        end
    end
  end

  # Optimistic lock: only set embed_hash if content_hash hasn't changed since
  # we started embedding. If it changed (concurrent edit), this is a no-op —
  # the reconciliation cron or the next debounced job will pick up the new version.
  defp stamp_embed_hash(%Note{content_hash: nil}), do: :ok

  defp stamp_embed_hash(note) do
    {count, _} =
      from(n in Note,
        where: n.id == ^note.id and n.content_hash == ^note.content_hash
      )
      |> Repo.update_all([set: [embed_hash: note.content_hash]], skip_tenant_check: true)

    if count == 0 do
      Logger.info("embed_hash stamp skipped (concurrent edit): note_id=#{note.id}")
    end

    :ok
  end

  @doc """
  Build an Oban job with 5-second debounce.
  `replace: [:scheduled_at]` resets the timer on rapid edits (dedup by note_id).

  Pass `old_path_hmac:` (base64) when the note was renamed — the worker will
  delete old-path Qdrant points before re-indexing under the new path. T3.2:
  HMAC bytes (not plaintext path) are what survives in `oban_jobs.args` JSONB.
  """
  def new_debounced(note_id, opts \\ []) do
    scheduled_at = DateTime.add(DateTime.utc_now(), 5, :second)
    args = %{note_id: note_id}

    args =
      if opts[:old_path_hmac],
        do: Map.put(args, :old_path_hmac, opts[:old_path_hmac]),
        else: args

    new(
      args,
      scheduled_at: scheduled_at,
      replace: [:scheduled_at]
    )
  end
end
