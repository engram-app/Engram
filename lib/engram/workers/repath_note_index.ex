defmodule Engram.Workers.RepathNoteIndex do
  @moduledoc """
  Oban worker: re-paths a note's Qdrant points after a rename WITHOUT
  re-embedding (#746). Point IDs are random UUIDs preserved across rename and
  the payload AAD binds to point-UUID, so dense/sparse vectors and ciphertext
  survive — only the plaintext `path_hmac`/`folder_hmac` filter-keys change.

  Branches on the point count under the OLD path_hmac:

    * count > 0                                -> PATCH new hmacs onto the points
    * count == 0 and content_hash != embed_hash -> enqueue EmbedNote (embed fresh)
    * count == 0 and content_hash == embed_hash -> warn: benign on rapid multi-rename
      (A→B→C) or when a content-edit EmbedNote wins the race; not an error

  On repeated Qdrant failure (count or PATCH), Oban retries up to max_attempts.
  On the final attempt, instead of discarding with stranded points, the worker
  falls back to `EmbedNote` with `old_path_hmac` — which deletes old-path points
  and re-embeds under the new path — so no points ever strand permanently.

  Every branch emits one `[:engram, :indexing, :repath, :stop]` telemetry event
  with `%{count}` and a bounded `%{outcome: :ok | :missing_points | :fallback}`
  tag, mapped to Prometheus by `Engram.PromEx.Indexing` (#753).

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
  def perform(%Oban.Job{args: args} = job) do
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
                # `count` is the number of points patched.
                emit_repath(:ok, count)
                :ok

              {:error, _} = err ->
                maybe_fallback(job, note, old_path_hmac, err)
            end

          {:ok, 0} ->
            handle_no_points(note)

          {:error, _} = err ->
            maybe_fallback(job, note, old_path_hmac, err)
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

    emit_repath(:missing_points, 1)
    :ok
  end

  # On the final attempt, fall back to EmbedNote (with old_path_hmac so it
  # deletes old-path points AND re-embeds under the new path). This ensures no
  # points ever strand under a stale path_hmac after all retries are exhausted.
  defp maybe_fallback(%Oban.Job{attempt: a, max_attempts: m} = _job, note, old_path_hmac, _err)
       when a >= m do
    _ =
      Enqueue.enqueue(
        EmbedNote.new_debounced(note.id, old_path_hmac: old_path_hmac),
        "embed_note"
      )

    Logger.warning(
      "repath exhausted #{m} attempts for note #{note.id}; falling back to EmbedNote",
      Metadata.with_category(:warning, :search, note_id: note.id)
    )

    emit_repath(:fallback, 1)
    :ok
  end

  defp maybe_fallback(_job, _note, _old_path_hmac, err), do: err

  # Single repath telemetry event tagged by a bounded `:outcome` so PromEx maps
  # one counter + one points-sum (see `Engram.PromEx.Indexing`). Cardinality
  # contract: `:outcome` only — never note_id/user_id/vault_id. `count` is the
  # number of points patched on `:ok`, and 1 (an event tick) otherwise.
  defp emit_repath(outcome, count) do
    :telemetry.execute(
      [:engram, :indexing, :repath, :stop],
      %{count: count},
      %{outcome: outcome}
    )
  end
end
