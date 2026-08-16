defmodule Engram.Notes.Identity do
  @moduledoc """
  The only writer of a vault's `filemeta_v0` map from server code.

  This map owns "which note is at which path" — see
  `docs/context/crdt-identity-authority.md` for the decision and what it
  supersedes. `Engram.Workers.ProjectVaultIndex` derives the `notes.path_*`
  columns from it.

  So a server-side rename does not change a path and then tell the index. It
  CLAIMS the path here — that is the commit — and the row is brought into line
  afterwards. The ordering is the entire point: a claim that lands and a row
  that does not converges toward the rename the user asked for, whereas a row
  that moves and a claim that does not gets REVERTED by the next projection run.

  ## Not best effort

  Every other side effect on the rename path (link rewrites, Qdrant repath,
  broadcasts) is fire-and-forget, because it is derived and can be rebuilt. This
  one is not derived — it IS the record. `claim/3` and `release/3` return errors
  and the caller must fail the rename on one, because a rename whose claim did
  not land did not happen.

  ## Removals are id-keyed, never path-keyed

  Entries are removed by matching `note_id`, not by deleting whatever sits at a
  path. Deleting by path clobbers the entry of whichever OTHER note legitimately
  holds it — and projection triggers exactly that against itself on its chain
  case (note A moving to the path note B is vacating): a path-keyed removal of
  A's old path deletes B's live entry before the fixpoint loop reaches it.

  ## Where it writes

  If the vault's index room is live the update goes through the room, and the
  room's own checkpoint persists it. Otherwise the persisted snapshot is
  rewritten in place.

  Deliberately NOT `ensure_started/2`: `auto_exit` is `:DOWN`-driven, so a room
  started here with no observer would never exit — an immortal orphan per
  rename.
  """
  alias Engram.Crypto.RotationGate
  alias Engram.Notes.{CrdtIndexDoc, CrdtIndexPersistence}
  alias Yex.Sync.SharedDoc

  @typedoc "A path claim: this note now lives here."
  @type claim :: {path :: String.t(), note_id :: String.t()}

  @doc """
  Claim `entries` (`[{path, note_id}]`) for their notes.

  Applied as one update, so a folder cascade or a batch move is a single
  atomic claim rather than N racing ones. Any other entry naming one of these
  notes is dropped, which is what makes a claim a MOVE rather than a copy.
  """
  @spec claim(map(), String.t(), [claim()]) :: :ok | {:error, term()}
  def claim(user, vault_id, entries)

  def claim(_user, _vault_id, []), do: :ok

  def claim(user, vault_id, entries) do
    apply_targets(user, vault_id, Enum.map(entries, fn {path, id} -> {id, path} end))
  end

  @doc """
  Drop every entry naming any of `note_ids` — the note is gone.
  """
  @spec release(map(), String.t(), [String.t()]) :: :ok | {:error, term()}
  def release(user, vault_id, note_ids)

  def release(_user, _vault_id, []), do: :ok

  def release(user, vault_id, note_ids) do
    apply_targets(user, vault_id, Enum.map(note_ids, &{&1, :gone}))
  end

  defp apply_targets(user, vault_id, targets) do
    case :global.whereis_name({:crdt_index, vault_id}) do
      pid when is_pid(pid) -> via_room(pid, user, vault_id, targets)
      :undefined -> via_snapshot(user, vault_id, targets)
    end
  end

  # `update_doc/2` returns :ok and DISCARDS the fun's value, so a claim that
  # refuses has to be posted back out of the room process. The call is
  # synchronous, so the message is already in the mailbox when it returns; the
  # timeout is a backstop, not a wait.
  defp via_room(room, user, vault_id, targets) do
    caller = self()
    ref = make_ref()

    SharedDoc.update_doc(room, fn doc -> send(caller, {ref, mutate(doc, targets)}) end)

    receive do
      {^ref, result} -> result
    after
      5_000 -> {:error, :room_silent}
    end
  catch
    :exit, _ ->
      # The room exited between the lookup and the call. Fall back to the
      # snapshot it just wrote on its way out.
      via_snapshot(user, vault_id, targets)
  end

  # The snapshot path ENCRYPTS, so it carries #1341: `users.encrypted_dek` holds
  # the OLD wrapped dek until `final_flip`, the last rotation phase, so a write
  # landing mid-rotation encrypts under a key that is about to retire and lands
  # on a row the sweep already re-wrapped — unreadable afterwards by anything.
  #
  # Because the claim is the commit, this cannot be skipped-and-continued the
  # way a derived side effect could: half-applying a rename is worse than
  # refusing it. The room path needs no gate — it only mutates memory, and the
  # room's own checkpoint is already gated.
  defp via_snapshot(user, vault_id, targets) do
    case RotationGate.check_user(user) do
      {:error, :rotation_in_progress} = err ->
        err

      _ ->
        with {:ok, doc} <- CrdtIndexPersistence.load_doc(user, vault_id),
             :ok <- mutate(doc, targets),
             :ok <- CrdtIndexPersistence.persist_doc(user, vault_id, doc) do
          recheck_room(user, vault_id, targets)
        end
    end
  end

  # Closes the read-modify-write race `CrdtIndexPersistence` documents as
  # residual risk: a room can bind the OLD snapshot while we are between our
  # read and our write, and the room's `unbind` REPLACES the row rather than
  # merging it — silently discarding the claim.
  #
  # Re-applying through a room that appeared meanwhile is safe because `mutate`
  # is idempotent: it asserts "this id lives at this path", so applying it twice
  # is indistinguishable from applying it once.
  defp recheck_room(user, vault_id, targets) do
    case :global.whereis_name({:crdt_index, vault_id}) do
      pid when is_pid(pid) -> via_room(pid, user, vault_id, targets)
      :undefined -> :ok
    end
  end

  defp mutate(doc, targets) do
    map = Yex.Doc.get_map(doc, CrdtIndexDoc.map_name())
    current = Yex.Map.to_map(map)

    case occupied_by_another(current, targets) do
      nil ->
        Enum.each(targets, fn {note_id, path} ->
          stale = stale_entries(current, note_id, path)
          Enum.each(stale, fn {key, _value} -> Yex.Map.delete(map, key) end)

          if path != :gone do
            Yex.Map.set(map, path, entry(current, stale, path, note_id))
          end
        end)

        :ok

      _path ->
        {:error, :conflict}
    end
  end

  # A claim onto a path a DIFFERENT note already holds is refused, and the whole
  # batch is refused with it.
  #
  # Displacing instead would deadlock. The loser's entry would be overwritten,
  # leaving it unclaimed — and projection is additive-corrective, so it never
  # acts on a note the map does not mention. The loser's ROW therefore never
  # moves, the row-level unique constraint it holds is never released, and the
  # winner can never derive either. Both notes stuck, permanently.
  #
  # This is uniqueness enforced at the authority rather than at the row, which
  # is the point: the map decides, and the column follows.
  defp occupied_by_another(current, targets) do
    Enum.find_value(targets, fn
      {_note_id, :gone} ->
        nil

      {note_id, path} ->
        case Map.get(current, path) do
          %{"note_id" => held} when held != note_id -> path
          _ -> nil
        end
    end)
  end

  # Every entry naming this note EXCEPT one already at its target path. A
  # non-map value never matches, so a malformed entry is left alone rather than
  # crashing a rename.
  defp stale_entries(current, note_id, path) do
    Enum.filter(current, fn
      {key, %{"note_id" => ^note_id}} -> key != path
      _ -> false
    end)
  end

  # Carry the moved entry's other fields across. The doc shape is
  # `path -> %{note_id, type, hash}` and only `note_id` is ours to assert, so
  # synthesizing a fresh single-field map would silently drop a `hash` the
  # client wrote — invisible today because nothing reads it, and a real
  # regression once Engram-obsidian#362/#363 does.
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
end
