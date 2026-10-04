defmodule Engram.Workers.ResparseNote do
  @moduledoc """
  Oban worker: rebuild one note's keyword (sparse) vectors in place via
  `Indexing.resparse_note/2`. No embedder call and no Voyage spend. Enqueued
  per note by `ReindexKeyword` in `:sparse` mode after a tokenizer change.

  Reads the same decrypted `notes.content` facade the embed pipeline indexed
  from, so its chunks fingerprint-match the stored points.

  A note with points that cannot be matched (no fingerprint, or edited since
  its last index) would keep stale keyword vectors forever: `embed_hash`
  still equals `content_hash`, so nothing else revisits it. Those notes are
  flagged and re-embedded in full instead. That bills the embedder, but only
  for legacy rows.
  """
  use Oban.Worker,
    queue: :embed,
    max_attempts: 5,
    unique: [period: 3600, keys: [:note_id], states: [:available, :scheduled]]

  alias Engram.Crypto
  alias Engram.Crypto.RotationGate
  alias Engram.Indexing
  alias Engram.Logger.Metadata
  alias Engram.Repo
  alias Engram.Workers.{BackgroundPriority, EmbedNote}

  require Logger

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    :ok = BackgroundPriority.demote()

    with {:ok, note} <- Engram.Notes.fetch_note_for_worker_job(args),
         :ok <- RotationGate.check(note.user_id),
         user = Engram.Accounts.get_user!(note.user_id),
         {:ok, note} <- Crypto.maybe_decrypt_note_fields(note, user),
         {:ok, _updated, unmatched} <- Indexing.resparse_note(note, user) do
      if unmatched > 0, do: rebuild(note, unmatched), else: :ok
    else
      {:discard, _} = discard -> discard
      {:error, :rotation_in_progress} -> {:snooze, 60}
      {:error, :user_not_found} -> {:discard, :user_deleted}
      {:error, _} = err -> err
    end
  end

  defp rebuild(note, unmatched) do
    Logger.warning(
      "resparse fell back to a full rebuild",
      Metadata.with_category(:warning, :oban, note_id: note.id, count: unmatched)
    )

    Repo.with_tenant!(note.user_id, fn -> Indexing.flag_notes_for_rebuild([note.id]) end)

    {:ok, _} =
      Oban.insert(
        EmbedNote.new_debounced(note.id, note.user_id, priority: EmbedNote.backfill_priority())
      )

    :ok
  end
end
