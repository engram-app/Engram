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
  alias Engram.Links
  alias Engram.Notes.Enqueue
  alias Engram.Workers.IndexCapMaintenance
  alias Engram.Workers.RebindNoteLinks

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  # T3.7 — NO rotation gate needed here. `Indexing.delete_note_index/1` only
  # uses `path_hmac` as a filter key to delete Qdrant points and DB chunk rows;
  # `Links.on_note_soft_deleted/2` is raw SQL (no decrypt). Neither touches
  # the DEK. The chained `RebindNoteLinks` job (below) DOES need the DEK, so
  # IT carries its own rotation gate rather than this worker gating for it.
  @impl Oban.Worker
  def perform(%Oban.Job{
        args:
          %{
            "note_id" => note_id,
            "user_id" => user_id,
            "vault_id" => vault_id,
            "path_hmac" => path_hmac_b64
          } = args
      }) do
    # `Indexing.delete_note_index/1` reads `note.path_hmac` directly. We
    # decode the base64 arg back into the raw HMAC bytes the function
    # expects on `note` rows. Skipping the user/vault enrichment because
    # `Indexing.delete_note_index/1` only needs a struct-like with
    # `:user_id`, `:vault_id`, `:path_hmac`, and `:id`.
    case Base.decode64(path_hmac_b64) do
      {:ok, path_hmac} ->
        note = %{id: note_id, user_id: user_id, vault_id: vault_id, path_hmac: path_hmac}
        _ = Indexing.delete_note_index(note)

        # #591 — the note is gone: drop its outgoing edges and flip any
        # incoming edges back to dangling.
        :ok = Links.on_note_soft_deleted(user_id, note_id)

        # Chain a rebind for the deleted note's OWN basename — a same-
        # basename sibling elsewhere may now win the shortest-path tiebreak
        # and should inherit the edges this note is vacating. Only possible
        # when the enqueueing caller had plaintext in scope to compute the
        # hmac (see `Notes.delete_note_index_job/2`); otherwise skip — the
        # edge-flip above already ran regardless. `basename_hmac` (base64) —
        # never plaintext, same T3.2/H3 invariant as `path_hmac` above.
        _ = maybe_enqueue_rebind(user_id, vault_id, Map.get(args, "basename_hmac"))

        # Deleting a note frees an indexed-note slot. The note that inherits it
        # already carries a stamped embed_hash from the pass that skipped it, so
        # nothing would ever re-index it. No-op for uncapped tiers.
        #
        # ENQUEUED, not inline. The sweep is whole-vault, and this worker runs
        # once per DELETED note — a 5,000-note folder delete ran it 5,000 times
        # over the same rows. The job is unique per (user, kind) over a 2-minute
        # window, so a delete burst collapses to one sweep after it settles.
        _ = IndexCapMaintenance.enqueue(user_id, :backfill_slots)

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

  defp maybe_enqueue_rebind(_user_id, _vault_id, nil), do: :ok

  defp maybe_enqueue_rebind(user_id, vault_id, basename_hmac_b64) do
    case Base.decode64(basename_hmac_b64) do
      {:ok, basename_hmac} ->
        Enqueue.enqueue(
          RebindNoteLinks.new_for(user_id, vault_id, basename_hmac),
          "rebind_note_links"
        )

      :error ->
        :ok
    end
  end
end
