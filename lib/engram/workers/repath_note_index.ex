defmodule Engram.Workers.RepathNoteIndex do
  @moduledoc """
  Oban worker: re-paths a note's Qdrant points after a rename WITHOUT
  re-embedding (#746). Point IDs are random UUIDs preserved across rename and
  the payload AAD binds to point-UUID, so dense/sparse vectors and ciphertext
  survive — only the plaintext `path_hmac`/`folder_hmac` filter-keys change.

  Branches on the point count under the OLD path_hmac:

    * count > 0                                -> PATCH new hmacs onto the points
    * count == 0 and content_hash != embed_hash -> enqueue EmbedNote (embed fresh)
    * count == 0 and content_hash == embed_hash -> warn: embedded note lost its
      points (real inconsistency; reconciler #264 owns repair)

  Shares the `:embed` queue with EmbedNote; repath jobs are cheap (no Voyage)
  so they don't meaningfully starve embeds.
  """

  use Oban.Worker,
    queue: :embed,
    max_attempts: 5,
    unique: [period: 120, keys: [:note_id, :old_path_hmac], states: :incomplete]

  alias Engram.Indexing
  alias Engram.Logger.Metadata
  alias Engram.Notes.Enqueue
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Workers.EmbedNote

  require Logger

  @doc """
  Build a deduped job. `old_path_hmac` is the base64 HMAC of the pre-rename
  path (T3.2 — never plaintext). Scheduled a few seconds out so the rename
  txn's broadcasts settle first; replaced on re-insert within the window.
  """
  def new_debounced(note_id, opts \\ []) do
    args = %{note_id: note_id, old_path_hmac: Keyword.fetch!(opts, :old_path_hmac)}
    new(args, schedule_in: 3, replace: [:scheduled_at])
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    note_id = args["note_id"]
    old_path_hmac = args["old_path_hmac"]

    # skip_tenant_check: trusted internal worker, scoped by note_id.
    case Repo.get(Note, note_id, skip_tenant_check: true) do
      nil ->
        {:discard, "note #{note_id} not found"}

      %Note{deleted_at: deleted_at} when deleted_at != nil ->
        {:discard, "note #{note_id} is soft-deleted"}

      note ->
        case Indexing.count_points_by_path_hmac(note, old_path_hmac) do
          {:ok, count} when count > 0 ->
            case Indexing.repath_points(note, old_path_hmac) do
              :ok ->
                # #746 — Grafana proof that rename took the cheap path (0 Voyage).
                :telemetry.execute(
                  [:engram, :indexing, :repath, :ok],
                  %{count: count},
                  %{note_id: note.id}
                )

                :ok

              other ->
                other
            end

          {:ok, 0} ->
            handle_no_points(note)

          {:error, _} = err ->
            err
        end
    end
  end

  # Zero points under the old path. Either the note still needs embedding
  # (embed it fresh under the new path), or it claims to be embedded but its
  # points vanished (a real inconsistency we surface, not silently swallow).
  defp handle_no_points(%Note{content_hash: ch, embed_hash: eh} = note) when ch != eh do
    _ = Enqueue.enqueue(EmbedNote.new_debounced(note.id), "embed_note")
    :ok
  end

  defp handle_no_points(%Note{} = note) do
    Logger.warning(
      "repath found zero Qdrant points for embedded note #{note.id}",
      Metadata.with_category(:warning, :search, note_id: note.id)
    )

    :telemetry.execute(
      [:engram, :indexing, :repath, :missing_points],
      %{count: 1},
      %{note_id: note.id}
    )

    :ok
  end
end
