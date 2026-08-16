defmodule Engram.Workers.ReleaseIndexEntries do
  @moduledoc """
  Drop `filemeta_v0` entries for notes that have been deleted (#1151 step 2).

  ## Why a job, when claiming is inline

  A CLAIM is the commit, so it must happen before the row moves and inline —
  see `Engram.Notes.Identity`. A RELEASE is the opposite: it is cleanup after
  the row is already gone, and it must not run before the delete is durable.

  That difference matters because the bulk delete paths run inside a
  transaction. `Engram.Folders.delete/4` and `Notes.batch_delete_folders/3`
  both wrap the cascade, and `Identity` reaches Postgres through
  `Repo.with_tenant/2`, which JOINS an in-flight transaction. Releasing inline
  from there breaks both ways:

  * **No live room** — the snapshot write joins the transaction and rolls back
    with it. If the notes leg commits but the release failed, the entries
    survive as permanent path reservations.
  * **Live room** — the room write is in MEMORY and does not roll back. If a
    later leg fails (the attachment leg in `Folders.delete/4` is the real
    case), the notes come back but their entries are gone. Live notes that the
    authority does not mention: projection is additive-corrective and never
    acts on absence, so they stay unclaimed forever and their paths are free
    for a different note to take.

  Enqueueing fixes both by construction. `Oban.insert/1` goes through the same
  repo, so the job rolls back with the transaction that created it and only
  runs once the delete is committed.

  It also replaces a discarded return value with a retry. The old call sites
  wrote `_ = Identity.release(...)`, so a release refused mid-rotation — the
  window when bulk deletes are most likely to be running — vanished silently
  and left one permanent reservation per note.

  ## Args carry ids, never paths

  `note_ids` are UUIDs. `oban_jobs.args` is unencrypted JSONB, and
  `NoPlaintextArgsTest` bans plaintext paths there. Releases are id-keyed
  anyway, so nothing here needs a path.

  ## Consistency

  A path is briefly still claimed by a deleted note between the commit and this
  job running. Nothing can *resurrect* the note (projection's `get_note_by_id`
  is `scoped_live`, so the entry reads as an unknown note), and creating a file
  at that path is unaffected because creation does not claim. Only a RENAME
  onto that exact path inside the window is refused, and it succeeds on retry.
  """
  use Oban.Worker, queue: :crdt_checkpoint, max_attempts: 5

  alias Engram.Accounts
  alias Engram.Crypto.RotationGate
  alias Engram.Notes.Identity

  @doc """
  Build a release job. Returns `:skip` for an empty id list so callers do not
  each need their own guard (`Enqueue.enqueue/3` no-ops on `:skip`).
  """
  @spec new_for(String.t(), String.t(), [String.t()]) :: Ecto.Changeset.t() | :skip
  def new_for(_user_id, _vault_id, []), do: :skip

  def new_for(user_id, vault_id, note_ids) do
    new(%{user_id: user_id, vault_id: vault_id, note_ids: note_ids})
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "vault_id" => vault_id} = args}) do
    note_ids = Map.get(args, "note_ids", [])

    case Accounts.get_user(user_id) do
      # Purged mid-flight (#954). The vault's index went with it.
      nil ->
        :ok

      user ->
        # The snapshot path encrypts, so it carries #1341. Snoozing rather than
        # skipping is the point of being a job: a skipped release leaves a
        # permanent path reservation, and rotations are exactly when bulk
        # deletes keep running.
        case RotationGate.check_user(user) do
          {:error, :rotation_in_progress} -> {:snooze, 30}
          :ok -> release(user, vault_id, note_ids)
        end
    end
  end

  defp release(user, vault_id, note_ids) do
    case Identity.release(user, vault_id, note_ids) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
