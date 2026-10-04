defmodule Engram.Workers.ResparseNote do
  @moduledoc """
  Oban worker: rebuild one note's keyword (sparse) vectors in place via
  `Indexing.resparse_note/2`. No embedder call and no Voyage spend. Enqueued
  per note by `ReindexKeyword` in `:sparse` mode after a tokenizer change.

  Reads the same decrypted `notes.content` facade the embed pipeline indexed
  from, so its chunks fingerprint-match the stored points.

  Also enqueued by `ReconcileEmbeddings` for every note whose
  `keyword_version` is behind `Engram.KeywordIndex.version/0`, so a keyword
  encoding change heals itself with no operator step. Success stamps the
  version.

  A note with points that cannot be matched (no fingerprint, or edited since
  its last index) would keep stale keyword vectors forever: `embed_hash`
  still equals `content_hash`, so nothing else revisits it. Those notes are
  flagged and re-embedded in full instead. That bills the embedder, but only
  for legacy rows, and never over a spent embed budget: that pass would run
  sparse-only and delete the note's dense points, so the note is parked.
  """
  use Oban.Worker,
    queue: :embed,
    max_attempts: 5,
    unique: [period: 3600, keys: [:note_id], states: [:available, :scheduled]]

  import Ecto.Query

  alias Engram.Crypto
  alias Engram.Crypto.RotationGate
  alias Engram.Indexing
  alias Engram.KeywordIndex
  alias Engram.Logger.Metadata
  alias Engram.Notes.Note
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
         # With the subscription: the fallback's budget check reads the plan.
         user = Engram.Accounts.get_user_with_subscription!(note.user_id),
         {:ok, note} <- Crypto.maybe_decrypt_note_fields(note, user),
         {:ok, _updated, unmatched} <- Indexing.resparse_note(note, user) do
      cond do
        unmatched == 0 -> stamp_keyword_version(note)
        EmbedNote.embed_budget_left?(user) -> rebuild(note, unmatched)
        true -> EmbedNote.park_over_budget(note)
      end
    else
      {:discard, _} = discard -> discard
      {:error, :rotation_in_progress} -> {:snooze, 60}
      {:error, :user_not_found} -> {:discard, :user_deleted}
      {:error, _} = err -> err
    end
  end

  # Every point now carries the current keyword encoding, so the note leaves
  # ReconcileEmbeddings' keyword sweep. Guarded on the content it read: an edit
  # that landed meanwhile is EmbedNote's to index (and stamp).
  defp stamp_keyword_version(note) do
    {:ok, _} =
      Repo.with_tenant(note.user_id, fn ->
        Repo.update_all(
          from(n in Note, where: n.id == ^note.id and n.content_hash == ^note.content_hash),
          set: [keyword_version: KeywordIndex.version()]
        )
      end)

    :ok
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
