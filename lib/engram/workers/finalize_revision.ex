defmodule Engram.Workers.FinalizeRevision do
  @moduledoc """
  Moves note-version outbox copies into storage (#1710).

  `Engram.Notes.Revisions.record_write/4` closes a version by copying the
  note's old content ciphertext into the row (`pending_*`). This decrypts that
  copy with the notes AAD, gzips it, re-encrypts it bound to the revision id,
  stores it through `Engram.Storage`, and clears the copy.

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
  open for the length of one upload. That is acceptable on the `maintenance`
  queue (worker nodes only, concurrency 2).

  ## A copy that can never decrypt

  `{:error, :decrypt_failed}` is permanent: retrying cannot change the bytes.
  Such a row gets `finalize_failed_at` and is skipped from then on, by this job
  and by the sweep, so it cannot block the note's later versions. Any other
  error (a storage PUT, a DEK fetch) is transient: the job still attempts every
  other version, then returns the first such error so Oban retries.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 10

  import Ecto.Query

  alias Engram.{Accounts, Crypto, Repo, Storage}
  alias Engram.Crypto.Envelope
  alias Engram.Logger.Metadata
  alias Engram.Notes.{Revision, Revisions}

  require Logger

  @doc """
  Finalize a note's pending copies a few seconds after the write, collapsing
  bursts. `:skip` while history recording is off: no write leaves a copy then,
  and a no-op job per save would crowd the 2-slot `maintenance` queue.
  `Engram.Notes.Enqueue.enqueue/2` drops `:skip`.
  """
  @spec new_for_note(String.t(), String.t()) :: Oban.Job.changeset() | :skip
  def new_for_note(note_id, user_id) when is_binary(note_id) and is_binary(user_id) do
    if Application.get_env(:engram, :history_recording, false),
      do: job(note_id, user_id),
      else: :skip
  end

  @doc """
  The job itself, regardless of the switch. The sweep uses this: copies written
  before recording was switched off still need moving to storage.
  """
  @spec job(String.t(), String.t()) :: Oban.Job.changeset()
  def job(note_id, user_id) when is_binary(note_id) and is_binary(user_id) do
    new(%{note_id: note_id, user_id: user_id},
      schedule_in: 5,
      unique: [period: 60, keys: [:note_id], states: [:available, :scheduled, :retryable]]
    )
  end

  # Finite so a hung storage PUT cannot pin a maintenance slot forever (#1496).
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
            rev |> upload(user) |> park_if_undecryptable(rev)

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
      {ct, nonce} = Envelope.encrypt(:zlib.gzip(text), dek, aad)
      key = Storage.revision_key(rev.user_id, rev.vault_id, rev.note_id, rev.id)

      with :ok <- Storage.adapter().put(key, ct, content_type: "application/octet-stream") do
        {1, _} =
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

        :ok
      end
    end
  end

  # Still under the advisory lock taken in finalize_one/2.
  defp park_if_undecryptable({:error, :decrypt_failed} = reason, rev) do
    now = DateTime.utc_now()

    {1, _} =
      Repo.update_all(from(r in Revision, where: r.id == ^rev.id),
        set: [finalize_failed_at: now, updated_at: now]
      )

    Logger.error(
      "finalize_revision parked an undecryptable copy note_id=#{rev.note_id} " <>
        "revision_id=#{rev.id} err=#{Metadata.safe_reason(reason)}",
      Metadata.with_category(:error, :oban, note_id: rev.note_id)
    )

    :ok
  end

  defp park_if_undecryptable(result, _rev), do: result
end
