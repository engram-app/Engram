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

  `Oban.insert_all` (the batch path, the hourly sweep) bypasses `unique`, so
  two runs can race on one version. Each would PUT under the same key with its
  own nonce, and only one nonce would reach the row, leaving the stored blob
  undecryptable. Taking `Repo.advisory_lock!/1` on the revision id, then
  re-reading under it, makes the second run see the copy already cleared.

  The lock is held across the storage PUT, which keeps a tenant transaction
  open for the length of one upload. That is acceptable on the `maintenance`
  queue (worker nodes only, concurrency 2).
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 10

  import Ecto.Query

  alias Engram.{Accounts, Crypto, Repo, Storage}
  alias Engram.Crypto.Envelope
  alias Engram.Notes.{Revision, Revisions}

  @doc "Finalize a note's pending copies a few seconds after the write, collapsing bursts."
  def new_for_note(note_id, user_id) when is_binary(note_id) and is_binary(user_id) do
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
            where: r.note_id == ^note_id and not is_nil(r.pending_ciphertext),
            select: r.id
          )
        )
      end)

    Enum.reduce_while(ids, :ok, fn id, :ok ->
      case finalize_one(id, user) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @doc false
  def finalize_one(revision_id, user) do
    {:ok, result} =
      Repo.with_tenant(user.id, fn ->
        Repo.advisory_lock!(revision_id)

        case Repo.get(Revision, revision_id) do
          %Revision{pending_ciphertext: ct} = rev when is_binary(ct) -> upload(rev, user)
          _already_done_or_gone -> :ok
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
end
