defmodule Engram.Workers.FinalizeRevision do
  @moduledoc """
  Moves note-version outbox copies into storage (#1710).

  `Engram.Notes.Revisions.record_write/4` closes a version by copying the
  note's old content ciphertext into the row (`pending_*`). This decrypts that
  copy with the notes AAD, re-encrypts it bound to the revision id, stores it
  through `Engram.Storage`, and clears the copy.

  ## Compression

  The blob is encrypted as plain text: the revision-content AAD is in the
  `Engram.Crypto.Envelope` compression policy, so `Envelope.encrypt/3`
  zstd-compresses it (format 1) when `:envelope_compression` is on. Blobs
  written before #1872 R2 were gzipped inside the envelope. No reader of
  revision blobs exists yet (#1711 builds one) and prod recording is off, so no
  gzip blobs are in the wild and none needs reading; the #1711 reader decrypts
  and uses the plaintext as is.

  One job per note, not per revision: it finalizes every pending copy the note
  holds. That keeps enqueueing free of return-value plumbing out of the write
  transaction. An empty run is one indexed query.

  ## Why the advisory lock

  `Oban.insert_all` (the hourly sweep) bypasses `unique`, so
  two runs can race on one version. Each would PUT under the same key with its
  own nonce, and only one nonce would reach the row, leaving the stored blob
  undecryptable. Taking `Repo.advisory_lock!/1` on the revision id, then
  re-reading under it, makes the second run see the copy already cleared.

  The lock is held across the storage PUT, which keeps a tenant transaction
  open for the length of one upload. That is acceptable on the `events`
  queue (worker nodes only, concurrency 2).

  ## A copy that can never decrypt

  `:decrypt_failed`, `:no_dek` and `:unrecognised_blob` are permanent:
  retrying cannot change the bytes or conjure a DEK. Such a row gets `finalize_failed_at` and is skipped from then on, by this job
  and by the sweep, so it cannot block the note's later versions. Any other
  error (a storage PUT, a DEK fetch) is transient: the job still attempts every
  other version, then returns the first such error so Oban retries.
  """
  use Oban.Worker, queue: :events, max_attempts: 10

  import Ecto.Query

  alias Engram.{Accounts, Crypto, Repo, Storage}
  alias Engram.Crypto.Envelope
  alias Engram.Logger.Metadata
  alias Engram.Notes.{Revision, Revisions}

  require Logger

  @doc """
  Finalize a note's pending copies a few seconds after the write, collapsing
  bursts. Write sites enqueue it only when `Revisions.finalize?/3` holds; the
  sweep enqueues it regardless, so copies written before recording was switched
  off still reach storage.
  """
  @spec job(String.t(), String.t()) :: Oban.Job.changeset()
  def job(note_id, user_id) when is_binary(note_id) and is_binary(user_id) do
    new(%{note_id: note_id, user_id: user_id},
      schedule_in: 5,
      unique: [period: 60, keys: [:note_id], states: [:available, :scheduled, :retryable]]
    )
  end

  # Finite so a hung storage PUT cannot pin an events slot forever (#1496).
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"note_id" => note_id, "user_id" => user_id}}) do
    case Accounts.get_user(user_id) do
      # The account is gone, and its note_revisions rows cascaded with it.
      nil -> :ok
      user -> finalize_note(note_id, user)
    end
  end

  defp finalize_note(note_id, user) do
    {:ok, ids} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(
          from(r in Revision,
            where:
              r.note_id == ^note_id and not is_nil(r.pending_ciphertext) and
                is_nil(r.finalize_failed_at),
            order_by: [asc: r.inserted_at, asc: r.id],
            select: r.id
          )
        )
      end)

    # Every version gets its attempt before a transient error is returned.
    ids
    |> Enum.map(&finalize_one(&1, user))
    |> Enum.find(:ok, &match?({:error, _}, &1))
  end

  @doc false
  def finalize_one(revision_id, user) do
    {:ok, result} =
      Repo.with_tenant(user.id, fn ->
        Repo.advisory_lock!(revision_id)

        case Repo.get(Revision, revision_id) do
          %Revision{pending_ciphertext: ct, finalize_failed_at: nil} = rev when is_binary(ct) ->
            rev |> upload(user) |> park_if_permanent(rev)

          _done_parked_or_gone ->
            :ok
        end
      end)

    result
  end

  defp upload(rev, user) do
    with {:ok, text} <- Revisions.decrypt_pending(rev, user),
         {:ok, dek} <- Crypto.get_dek(user) do
      aad = Crypto.aad_for_row(:note_revisions, :content, rev.id)
      {ct, nonce} = Envelope.encrypt(text, dek, aad)
      key = Storage.revision_key(rev.user_id, rev.vault_id, rev.note_id, rev.id)

      with :ok <- Storage.adapter().put(key, ct, content_type: "application/octet-stream") do
        Repo.update_all(from(r in Revision, where: r.id == ^rev.id),
          set: [
            storage_key: key,
            blob_nonce: nonce,
            char_count: String.length(text),
            dek_version: Crypto.row_version_aad_bound(),
            pending_ciphertext: nil,
            pending_nonce: nil,
            pending_dek_version: nil,
            updated_at: DateTime.utc_now()
          ]
        )
        |> case do
          {1, _} ->
            :ok

          # The row went (its note deleted, cascading) while the PUT ran. Remove
          # the blob it would have pointed at; nothing is left to finalize.
          {0, _} ->
            _ = Storage.adapter().delete(key)
            :ok
        end
      end
    end
  end

  # Errors retrying cannot change: the bytes will not decrypt, or the user has
  # no usable DEK at all. A KMS unwrap failure stays transient.
  @permanent [:decrypt_failed, :no_dek, :unrecognised_blob]

  # Still under the advisory lock taken in finalize_one/2.
  defp park_if_permanent({:error, reason}, rev) when reason in @permanent do
    now = DateTime.utc_now()

    {1, _} =
      Repo.update_all(from(r in Revision, where: r.id == ^rev.id),
        set: [finalize_failed_at: now, updated_at: now]
      )

    Logger.error(
      "finalize_revision parked a copy that cannot finalize note_id=#{rev.note_id} " <>
        "revision_id=#{rev.id} err=#{Metadata.safe_reason(reason)}",
      Metadata.with_category(:error, :oban, note_id: rev.note_id)
    )

    :ok
  end

  defp park_if_permanent(result, _rev), do: result
end
