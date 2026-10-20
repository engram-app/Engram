defmodule Engram.Workers.DeleteNoteIndex do
  @moduledoc """
  Oban worker: deletes Qdrant points and DB chunks for a soft-deleted note.

  Enqueued from `Notes.delete_note/3`. Args carry `path_hmac` (base64), not
  plaintext `path` — see encryption tier-3 audit T3.2 / H3. Plaintext in
  `oban_jobs.args` JSONB defeats Phase B at-rest encryption for the
  duration of any in-flight or recently-completed job.
  """

  use Oban.Worker, queue: :indexing, max_attempts: 3

  import Ecto.Query, only: [from: 2]

  alias Engram.Indexing
  alias Engram.Links
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Vector.Qdrant

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  # T3.7 — NO rotation gate needed here. `Indexing.delete_note_index/1` only
  # uses `path_hmac` as a filter key to delete Qdrant points and DB chunk rows;
  # `Links.on_note_soft_deleted/2` is raw SQL (no decrypt). Neither touches
  # the DEK.
  #
  # Jobs enqueued before resolve-on-read may still carry a `basename_hmac`
  # arg; it is ignored.
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

        # #1610: the note was resurrected before this ran (id-keyed rename,
        # restore). Wiping its index now would leave a live note unsearchable.
        #
        # ponytail: check-then-delete, no lock. A resurrect AND a completed
        # EmbedNote landing between this check and the Qdrant delete still get
        # wiped, with embed_hash stamped. Closing it means holding a row lock
        # across a Qdrant call; do that only if this is ever seen in prod.
        if live?(user_id, note_id), do: :ok, else: unlink_then_delete_index(note)

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

  # A failed Qdrant delete is returned so Oban retries it (#1608). Discarding
  # it left both the rows and the points, and the deleted note kept answering
  # searches with nothing left to retry the delete.
  #
  # The local work runs FIRST, and the retryable remote delete last. Behind the
  # delete, a brief Qdrant 5xx would burn all three attempts and the note would
  # keep its outgoing edges forever, since nothing re-enqueues this job. Each
  # step here is idempotent, so a retry repeating them is free.
  defp unlink_then_delete_index(%{id: note_id, user_id: user_id} = note) do
    # #591 — the note is gone: drop its outgoing edges.
    :ok = Links.on_note_soft_deleted(user_id, note_id)

    # Strict mode never refuses a delete; mapped anyway so a refusal is a
    # snooze here like on every other Qdrant writer.
    case Indexing.delete_note_index(note) do
      {:error, :qdrant_backpressure} -> Qdrant.backpressure_snooze(:refused)
      {:error, :qdrant_wait_timeout} -> Qdrant.wait_timeout_snooze()
      other -> other
    end
  end

  defp live?(user_id, note_id) do
    {:ok, live?} =
      Repo.with_tenant(user_id, fn ->
        Repo.exists?(
          from(n in Note, where: n.id == ^note_id and n.kind == "note" and is_nil(n.deleted_at))
        )
      end)

    live?
  end
end
