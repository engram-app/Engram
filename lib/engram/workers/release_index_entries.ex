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
  alias Engram.Notes.{Enqueue, Identity}

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  # Ids per link, and so per index-room change. Chosen by measurement (PR
  # body of the chunking follow-up to #2164; 20k stale ids, 500/1k/2k/5k/10k
  # per job): a job's cost is dominated by a FIXED part that scales with the
  # whole index (snapshot decrypt/re-encrypt, or the room edit plus encrypted
  # tail append), ~0.2-0.5 s at 20-40k entries, while each extra id adds ~0.05
  # ms. So small chunks multiply that fixed cost: 20k ids took 20 s at 500 per
  # job and 5.7 s at 2,000, with the slowest job the same (~0.8 s) at both.
  # Above 2,000 the slowest job and the delete set broadcast to every
  # connected client (~4 B per id worst case, 8 KB here) keep growing for a
  # shrinking total-time win.
  #
  # Deliberately NOT `Notes`' 500-row chunk: that one bounds SQL bind params,
  # a different limit this job never reaches.
  @chunk_size 2_000

  # No @spec: dialyzer infers the exact `2000`, and a wider `pos_integer()`
  # is a `contract_supertype` it rejects.
  @doc "Max note ids per link of a release chain, i.e. per index-room change."
  def chunk_size, do: @chunk_size

  # Wall time one link may spend before handing the rest to a successor. A
  # chunk costs ~0.8 s at 20-40k index entries but its fixed part grows with
  # the index, so a whole-chain loop could outrun `timeout/1` (5 min) on a
  # huge vault and retry from the top forever. A minute keeps every link far
  # inside the timeout while a typical storm (34k ids, ~14 s) is ONE job, and
  # successor args shrink by about a minute of work each.
  @default_link_budget_ms 60_000

  @doc "Wall-time budget per link, in ms. Config-overridable so tests can force a chain."
  def link_budget_ms,
    do: Application.get_env(:engram, :release_index_link_budget_ms, @default_link_budget_ms)

  @doc """
  Build ONE release job for `note_ids`, or `:skip` for none
  (`Enqueue.enqueue/3` no-ops on it).

  One job however many ids, on purpose. `perform/1` releases its ids
  `chunk_size/0` at a time, one index-room change per chunk, in series. If
  the job outlives `link_budget_ms/0` with ids left, it enqueues them as its
  successor and stops, so a chain never runs into the job timeout and a retry
  redoes at most one budget of (no-op) releases. A chain runs one link at a
  time. Enqueueing every chunk up front instead let a storm (17 chunks at 34k
  ids) fill every `crdt_checkpoint` slot with jobs that all wait on the same
  per-vault fold lock in `CrdtIndexPersistence`, each holding a pooled DB
  connection while `CheckpointNote` jobs starved behind them. It is also one
  atomic insert, so
  a caller never ends up with half its releases queued: a DB error raises and
  rolls the caller's transaction back, and any other `{:error, _}` is logged
  and counted by `Enqueue.enqueue/3` (`[:engram, :notes, :enqueue, :failed]`).
  """
  @spec new_for(String.t(), String.t(), [String.t()]) :: Ecto.Changeset.t() | :skip
  def new_for(_user_id, _vault_id, []), do: :skip

  def new_for(user_id, vault_id, note_ids),
    do: new(%{user_id: user_id, vault_id: vault_id, note_ids: note_ids})

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
        # deletes keep running. `check/1`: `user` is the cached row, which
        # may not have seen another node's lock yet.
        case RotationGate.check(user.id) do
          {:error, :rotation_in_progress} -> {:snooze, 30}
          {:error, :user_not_found} -> :ok
          :ok -> release(user, vault_id, note_ids)
        end
    end
  end

  defp release(user, vault_id, note_ids) do
    release_chunks(
      user,
      vault_id,
      note_ids,
      System.monotonic_time(:millisecond) + link_budget_ms()
    )
  end

  defp release_chunks(user, vault_id, note_ids, deadline) do
    {chunk, rest} = Enum.split(note_ids, @chunk_size)

    # See "Consistency" above: a note this job was told is gone may have
    # arrived since it was enqueued. `%{id: vault_id}` is the same
    # bare-map-as-vault shape `ProjectVaultIndex` uses. ONE metadata read per
    # chunk, not a full-row fetch and content decrypt per id.
    #
    # A failed read or release returns the error and Oban retries THIS job
    # with its args intact, so no id is lost; chunks it already released are
    # redone as no-ops. The successor is enqueued only after the last chunk
    # this link ran succeeded, and a failed insert retries this link too.
    with {:ok, present} <- Notes.get_note_meta_by_ids(user, %{id: vault_id}, chunk),
         :ok <- Identity.release(user, vault_id, Enum.reject(chunk, &Map.has_key?(present, &1))) do
      cond do
        rest == [] ->
          :ok

        System.monotonic_time(:millisecond) < deadline ->
          release_chunks(user, vault_id, rest, deadline)

        true ->
          enqueue_successor(user, vault_id, rest)
      end
    end
  end

  # ponytail: a successor carries every remaining id, so args written over a
  # chain are about (ids) x (links) / 2, and links = chain wall time / budget.
  # A 34k storm is one link (no successor). The worst case the 16 MB index
  # allows (~400k ids) is a few links of up to 16 MB each. Upgrade path if
  # that shows up: a cursor over a table of pending releases.
  defp enqueue_successor(user, vault_id, rest) do
    case Enqueue.enqueue(new_for(user.id, vault_id, rest), "release_index_entries") do
      {:ok, _job} -> :ok
      {:error, _} = err -> err
    end
  end
end
