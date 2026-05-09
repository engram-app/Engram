defmodule Engram.Workers.DeleteNoteIndex do
  @moduledoc """
  Oban worker: deletes Qdrant points and DB chunks for a soft-deleted note.

  Enqueued from `Notes.delete_note/3`. Args carry `path_hmac` (base64), not
  plaintext `path` — see encryption tier-3 audit T3.2 / H3. Plaintext in
  `oban_jobs.args` JSONB defeats Phase B at-rest encryption for the
  duration of any in-flight or recently-completed job.
  """

  use Oban.Worker, queue: :indexing, max_attempts: 3

  alias Engram.Indexing

  # T3.7 — NO rotation gate needed here. `Indexing.delete_note_index/1` only
  # uses `path_hmac` as a filter key to delete Qdrant points and DB chunk rows;
  # it does NOT decrypt or re-encrypt any payload. DEK access is never triggered.
  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "note_id" => note_id,
          "user_id" => user_id,
          "vault_id" => vault_id,
          "path_hmac" => path_hmac_b64
        }
      }) do
    # `Indexing.delete_note_index/1` reads `note.path_hmac` directly. We
    # decode the base64 arg back into the raw HMAC bytes the function
    # expects on `note` rows. Skipping the user/vault enrichment because
    # `Indexing.delete_note_index/1` only needs a struct-like with
    # `:user_id`, `:vault_id`, `:path_hmac`, and `:id`.
    case Base.decode64(path_hmac_b64) do
      {:ok, path_hmac} ->
        note = %{id: note_id, user_id: user_id, vault_id: vault_id, path_hmac: path_hmac}
        Indexing.delete_note_index(note)
        :ok

      :error ->
        {:discard, "invalid path_hmac base64 for note_id=#{note_id}"}
    end
  end

  # T3.2 — defensive fall-through. The strict head above expects the
  # post-T3.2 arg shape; the migration that ships in this PR deletes any
  # in-flight jobs carrying the legacy `path` key, but deploy ordering is
  # not load-bearing on this clause: any unrecognized shape is discarded
  # with a structured reason so a stale enqueue from a rolled-back deploy
  # does not raise FunctionClauseError + retry storm. Crucially, the
  # legacy `path` plaintext key is exactly the leak T3.2/H3 closed —
  # there is no scenario where we want to "process" such a job.
  def perform(%Oban.Job{args: args}) do
    {:discard, "T3.2 legacy or malformed args (keys=#{inspect(Map.keys(args))})"}
  end
end
