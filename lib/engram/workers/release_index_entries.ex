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
  job running. Nothing can *resurrect* a genuinely deleted note (projection's
  `get_note_by_id` is `scoped_live`, so the entry reads as an unknown note),
  and creating a file at that path is unaffected because creation does not
  claim. Only a RENAME onto that exact path inside the window is refused, and
  it succeeds on retry.

  That guarantee is what every caller BEFORE #1550 relied on: the row really
  is gone, permanently, by the time this job runs, because the caller enqueues
  it from inside (or right after) the transaction that deleted it. #1550's
  caller (`ProjectVaultIndex`) breaks that premise on purpose — it enqueues a
  release for a note it saw as MISSING, not deleted, and a missing note can
  still arrive: the create it's waiting on can land in the window between
  detection and this job running, especially under a `RotationGate` snooze.
  `Identity.release/3` deletes by note_id unconditionally with no such check,
  so `release/3` below re-verifies the note is still gone immediately before
  calling it — a no-op read for every pre-#1550 caller (their note really is
  gone), and the only thing standing between #1550's caller and un-indexing a
  note that just arrived.
  """
  use Oban.Worker, queue: :crdt_checkpoint, max_attempts: 5

  alias Engram.Accounts
  alias Engram.Crypto.RotationGate
  alias Engram.Notes
  alias Engram.Notes.Identity

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

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
    # See "Consistency" above: a note this job was told is gone may have
    # arrived since it was enqueued. `%{id: vault_id}` is the same
    # bare-map-as-vault shape `ProjectVaultIndex` uses — `get_note_by_id/3`
    # only ever reads `vault.id`.
    vault = %{id: vault_id}

    still_gone =
      Enum.reject(note_ids, fn note_id ->
        match?({:ok, _note}, Notes.get_note_by_id(user, vault, note_id))
      end)

    case Identity.release(user, vault_id, still_gone) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
