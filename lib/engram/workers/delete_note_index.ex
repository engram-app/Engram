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
end
