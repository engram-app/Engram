defmodule Engram.Workers.ResparseNote do
  @moduledoc """
  Oban worker: rebuild one note's keyword (sparse) vectors in place via
  `Indexing.resparse_note/2`. No embedder call and no Voyage spend. Enqueued
  per note by `ReindexKeyword` in `:sparse` mode after a tokenizer change.

  Reads the same decrypted `notes.content` facade the embed pipeline indexed
  from, so its chunks fingerprint-match the stored points.
  """
  use Oban.Worker,
    queue: :indexing,
    max_attempts: 5,
    unique: [period: 3600, keys: [:note_id], states: [:available, :scheduled]]

  alias Engram.Crypto
  alias Engram.Crypto.RotationGate
  alias Engram.Workers.BackgroundPriority

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    :ok = BackgroundPriority.demote()

    with {:ok, note} <- Engram.Notes.fetch_note_for_worker_job(args),
         :ok <- RotationGate.check(note.user_id),
         user = Engram.Accounts.get_user!(note.user_id),
         {:ok, note} <- Crypto.maybe_decrypt_note_fields(note, user),
         {:ok, _updated} <- Engram.Indexing.resparse_note(note, user) do
      :ok
    else
      {:discard, _} = discard -> discard
      {:error, :rotation_in_progress} -> {:snooze, 60}
      {:error, :user_not_found} -> {:discard, :user_deleted}
      {:error, _} = err -> err
    end
  end
end
