defmodule Engram.Workers.SyncVaultIndex do
  @moduledoc """
  Oban worker: mirror a server-side path change into a vault's `filemeta_v0`
  index (#1146 decision 4).

  `Engram.Workers.ProjectVaultIndex` makes the index authoritative for paths: an
  entry that disagrees with a row MOVES the row. So any path the SERVER changes
  must also land in the index, or the next projection run reverts it — tombstone
  at the new path, Qdrant repath, and a `delete` broadcast to every connected
  device.

  This is the mirror image of the guard `ProjectVaultIndex` already carries.
  That one says "do not write the path columns directly, go through
  `rename_note/4`". This one says "do not change a path without telling the
  index". Both exist because there are now two writers of identity and they must
  not disagree.

  Dual-write is the migration shape #1146 chose (decision 4). It ends when the
  client owns identity outright (Engram-obsidian#363).

  ## The args carry note ids, never paths

  Two independent constraints land on the same design, which is why this reads
  as over-indirect until you need both:

  1. `NoPlaintextArgsTest` bans plaintext paths in `oban_jobs.args`, correctly —
     `args` is an unencrypted JSONB column.
  2. Removing an index entry BY PATH is a live bug (see "Removal is id-keyed").

  Both dissolve the same way: the rename has already committed, so the note row
  is the authoritative record of its new path. This job re-derives paths from
  the rows at execution time and never needs to be told one.

  A consequence worth stating: this job reconciles to the note's path *when it
  runs*, not when it was enqueued. For a note renamed twice in quick succession
  that is the desired answer, and it is why deduplication below is safe.

  ## Why a job and not an inline call

  The first cut called into the index directly from `Notes.do_rename_note/6`.
  Three things were wrong with that, and moving to a job fixes all three:

  * **`batch_move_notes/4` runs its whole loop inside one `Repo.transaction`.**
    An inline write into a LIVE index room mutates another process's in-memory
    CRDT, which no rollback can undo. A batch that failed on id 7 left ids 1-6
    in the index at paths the API had just rejected, and the next projection run
    dutifully moved the rows to match. Enqueueing instead inherits the
    transaction: `Oban.insert/1` goes through the same repo, so a rolled-back
    batch takes its jobs with it.
  * **A failure had nowhere to go.** Post-commit, raising is wrong — it would
    report a completed rename as failed. So the inline version swallowed every
    error and returned `:ok`, and the cost of that is not "a stale index": since
    `do_rename_note/6` writes no tombstone at the old path, the old path is
    FREE, so projection's revert rename SUCCEEDS. A swallowed failure silently
    undid a completed user-visible rename. A job retries instead.
  * **Cost was per-note and unbounded.** With no live room, each note meant a
    full snapshot read, decrypt, decode, encode, encrypt and insert — inside
    that open transaction, holding a pool connection. One job covers N ids with
    one snapshot rewrite.

  ## Removal is id-keyed, never path-keyed

  Entries are removed by matching `note_id`, not by deleting whatever sits at a
  path. Deleting by path clobbers the entry of whichever OTHER note legitimately
  holds it — and `ProjectVaultIndex` triggers exactly that against itself. Its
  CHAIN case (note A moving to the path note B is vacating) has projection call
  `rename_note/4` for A while B's entry is still pending; a path-keyed removal
  of A's old path deletes B's live entry, and if the job dies before the
  fixpoint loop reaches B, B is gone from the authoritative index for good.

  ## Where it writes

  If the vault's index room is live the update goes through the room, and the
  room's own checkpoint persists it. Otherwise the persisted snapshot is
  rewritten in place.

  Deliberately NOT `ensure_started/2`: `auto_exit` is `:DOWN`-driven, so a room
  started here with no observer would never exit — an immortal orphan per
  rename.
  """
  use Oban.Worker, queue: :crdt_checkpoint, max_attempts: 5

  # NO `unique:`, deliberately. The dedupe we actually want is "collapse jobs
  # that have not started yet", and Oban cannot express it: every state group it
  # accepts includes `:executing`, and a job that has already read the rows
  # cannot pick up a rename that landed after it started — so deduplicating
  # against an executing job DROPS that rename. Running a redundant job is
  # cheap and idempotent; losing a rename is not.

  alias Engram.Accounts
  alias Engram.Crypto.RotationGate
  alias Engram.Logger.Metadata
  alias Engram.Notes
  alias Engram.Notes.{CrdtIndexDoc, CrdtIndexPersistence}
  alias Yex.Sync.SharedDoc

  require Logger

  @event [:engram, :crdt, :index_writeback]

  @doc """
  Build a write-back job for `note_ids` in `vault_id`.

  Pass every id whose path the caller just changed — a folder cascade should
  pass all of them in ONE job rather than one job per note.
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
      nil ->
        # Purged mid-flight. Expected, not exceptional (#954) — but counted.
        emit(:user_gone)
        :ok

      user ->
        # The snapshot path encrypts, so it carries #1341's hazard exactly:
        # `users.encrypted_dek` holds the OLD wrapped dek until `final_flip`, the
        # last rotation phase, so a write landing mid-rotation encrypts under the
        # old key onto a row `sweep_vault_index_states` has already re-wrapped —
        # unreadable by any key that still exists once the old one retires.
        #
        # Snoozing rather than skipping is the whole reason this is a job. A
        # skipped write-back is not merely stale: the index keeps the old path,
        # the old path is free, and projection moves the note BACK. Retrying
        # after the rotation costs a delay and loses nothing.
        case RotationGate.check_user(user) do
          {:error, :rotation_in_progress} ->
            emit(:snoozed_rotation)
            {:snooze, 30}

          _ ->
            sync(user, vault_id, note_ids)
        end
    end
  end

  defp sync(user, vault_id, note_ids) do
    case targets(user, vault_id, note_ids) do
      [] ->
        emit(:no_targets)
        :ok

      targets ->
        write(user, vault_id, targets)
    end
  end

  # Resolve each id to the path the row currently holds, which is what the index
  # must be made to agree with. A note that no longer resolves was deleted, and
  # `:gone` means "remove every entry naming it".
  #
  # A row whose path will not decrypt is SKIPPED, not treated as deleted: this
  # job's removals are id-keyed, so mistaking an unreadable row for a deleted
  # one would strip a live note out of the authoritative index.
  defp targets(user, vault_id, note_ids) do
    vault = %{id: vault_id}

    Enum.flat_map(note_ids, fn id ->
      case Notes.get_note_by_id(user, vault, id) do
        {:ok, note} when is_binary(note.path) ->
          [{id, note.path}]

        {:ok, _note} ->
          emit(:unreadable_path)

          Logger.error(
            "index write-back skipped a note with no readable path",
            Metadata.with_category(:error, :sync, user_id: user.id, vault_id: vault_id)
          )

          []

        {:error, :not_found} ->
          [{id, :gone}]
      end
    end)
  end

  defp write(user, vault_id, targets) do
    case :global.whereis_name({:crdt_index, vault_id}) do
      pid when is_pid(pid) -> via_room(pid, user, vault_id, targets)
      :undefined -> via_snapshot(user, vault_id, targets)
    end
  end

  defp via_room(room, user, vault_id, targets) do
    SharedDoc.update_doc(room, fn doc -> mutate(doc, targets) end)
    emit(:via_room)
    :ok
  catch
    :exit, _ ->
      # The room exited between the lookup and the call. Fall back to the
      # snapshot it just wrote on its way out.
      via_snapshot(user, vault_id, targets)
  end

  defp via_snapshot(user, vault_id, targets) do
    with {:ok, doc} <- CrdtIndexPersistence.load_doc(user, vault_id),
         :ok <- mutate(doc, targets),
         :ok <- CrdtIndexPersistence.persist_doc(user, vault_id, doc) do
      emit(:via_snapshot)
      recheck_room(user, vault_id, targets)
    else
      # PERMANENT: a snapshot that will not decrypt, or that decrypts to bytes
      # Yjs rejects, will not fix itself. Retrying burns attempts to reach the
      # same place.
      {:error, permanent} when permanent in [:decrypt_failed, :corrupt_snapshot] ->
        emit(permanent)

        Logger.error(
          "index write-back cannot read the snapshot: #{inspect(permanent)}",
          Metadata.with_category(:error, :sync, user_id: user.id, vault_id: vault_id)
        )

        :ok

      # TRANSIENT until proven otherwise — a KMS blip or a pool timeout must not
      # discard the write-back, because nothing else will re-trigger it.
      {:error, reason} ->
        emit(:failed)

        Logger.error(
          "index write-back failed, will retry: #{inspect(reason)}",
          Metadata.with_category(:error, :sync, user_id: user.id, vault_id: vault_id)
        )

        {:error, reason}
    end
  end

  # Closes the read-modify-write race that `CrdtIndexPersistence` documents as
  # residual risk: a room can bind the OLD snapshot while this job is between
  # its read and its write, and the room's `unbind` REPLACES the row rather than
  # merging — silently discarding the write-back.
  #
  # Re-applying through a room that appeared meanwhile is safe because `mutate`
  # is idempotent: it asserts "this id lives at this path", so running it twice
  # is indistinguishable from running it once.
  defp recheck_room(user, vault_id, targets) do
    case :global.whereis_name({:crdt_index, vault_id}) do
      pid when is_pid(pid) ->
        emit(:room_appeared)
        via_room(pid, user, vault_id, targets)

      :undefined ->
        :ok
    end
  end

  defp mutate(doc, targets) do
    map = Yex.Doc.get_map(doc, CrdtIndexDoc.map_name())
    current = Yex.Map.to_map(map)

    Enum.each(targets, fn {note_id, path} ->
      stale = stale_entries(current, note_id, path)
      Enum.each(stale, fn {key, _value} -> Yex.Map.delete(map, key) end)

      if path != :gone do
        Yex.Map.set(map, path, entry(current, stale, path, note_id))
      end
    end)

    :ok
  end

  # Every entry naming this note EXCEPT one already at its current path. Matching
  # on note_id rather than deleting a known path is the whole point — see
  # "Removal is id-keyed" above. A non-map value simply never matches, so
  # malformed entries are left alone rather than crashing the job.
  defp stale_entries(current, note_id, path) do
    Enum.filter(current, fn
      {key, %{"note_id" => ^note_id}} -> key != path
      _ -> false
    end)
  end

  # Carry the moved entry's other fields across. The doc shape is
  # `path -> %{note_id, type, hash}` and only `note_id` is ours to assert, so
  # synthesizing a fresh single-field map would silently drop a `hash` the client
  # wrote — invisible today because nothing reads it, and a real regression once
  # Engram-obsidian#362/#363 does.
  #
  # The fields travel WITH the note, so they come from the entry being retired,
  # not from whatever happens to sit at the destination.
  defp entry(current, stale, path, note_id) do
    carried =
      case stale do
        [{_key, value} | _] -> value
        [] -> Map.get(current, path)
      end

    carried = if is_map(carried), do: carried, else: %{}
    Map.put(carried, "note_id", note_id)
  end

  defp emit(phase) do
    :telemetry.execute(@event, %{count: 1}, %{phase: phase})
    :ok
  end
end
