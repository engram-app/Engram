defmodule Engram.Workers.RefreshKeywordVectors do
  @moduledoc """
  Oban worker: rebuild one note's keyword (sparse) vectors in place via
  `Indexing.resparse_note/2`. No embedder call and no Voyage spend. Enqueued
  per note by `ReconcileEmbeddings` after a tokenizer change.

  Reads the same decrypted `notes.content` facade the embed pipeline indexed
  from, so its chunks fingerprint-match the stored points.

  Also enqueued by `ReconcileEmbeddings` for every note whose
  `keyword_version` is behind `Engram.KeywordIndex.version/0`, so a keyword
  encoding change heals itself with no operator step. Success stamps the
  version.

  Named apart from its predecessor `ResparseNote` on purpose: during a rolling
  deploy, nodes on the previous release share the `embed` queue, and their
  `ResparseNote` still re-embedded unmatched notes. A worker name they do not
  have makes them fail the job harmlessly instead of billing Voyage.

  It never re-embeds. Points it cannot match (legacy rows with no
  fingerprint, v1 chunks whose blobs v2 strips) belong to notes with a stale
  `chunker_version`, which the chunker rebuild owns; see
  `docs/context/index-version-self-heal.md`.
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
  alias Engram.Parsers.Markdown
  alias Engram.Repo
  alias Engram.Workers.BackgroundPriority

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
      cond do
        unmatched == 0 ->
          stamp_keyword_version(note)

        note.chunker_version != Markdown.chunker_version() ->
          log_unmatched(note, unmatched)
          stamp_keyword_version(note)

        # Unmatched on a CURRENT chunker: nothing else will rebuild these
        # points (a DEK rotation clears every context_hmac without touching
        # content or chunker). Stay unstamped and say so; the sweep retries
        # once per cooldown window, which costs no embedder call.
        true ->
          Logger.warning(
            "resparse cannot match points on a current-chunker note",
            Metadata.with_category(:warning, :oban, note_id: note.id, count: unmatched)
          )
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
          from(n in Note,
            where: n.kind == "note" and n.id == ^note.id and n.content_hash == ^note.content_hash
          ),
          set: [keyword_version: KeywordIndex.version()]
        )
      end)

    :ok
  end

  # Never a re-embed from here. On a stale-chunker note, a point resparse
  # cannot match is a legacy row (no fingerprint) or a v1 chunk holding a
  # base64 blob v2 strips, and the chunker rebuild owns it.
  # Re-embedding here turned the automatic keyword sweep into a corpus-wide
  # Voyage bill and, over a spent Free budget, a sparse-only pass that drops
  # the note's dense points. The note is still stamped: its matched points are
  # current, and re-selecting it every tick would change nothing.
  defp log_unmatched(note, unmatched) do
    Logger.info(
      "resparse left unmatched points for the chunker rebuild",
      Metadata.with_category(:info, :oban, note_id: note.id, count: unmatched)
    )
  end
end
