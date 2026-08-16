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

  ## The map cannot enforce uniqueness on its own

  `claim/3` refuses a path another note already holds IN THE MAP. That check is
  necessary and not sufficient, because until Engram-obsidian#362 no client
  writes `filemeta_v0`, so in production almost every note has no entry and the
  map cannot see a collision with a ROW.

  Callers must therefore validate against the rows BEFORE claiming
  (`Engram.Notes.claim_rename/5` and the batch/cascade equivalents). Getting
  that wrong is not a stale entry: the claim is durable, the row write then
  fails, and the path becomes permanently unclaimable — every later claim on it
  is refused even though the rows are free, and if the row holding it is ever
  deleted, projection executes the rename the API rejected.

  ## Not best effort

  Every other side effect on the rename path (link rewrites, Qdrant repath,
  broadcasts) is fire-and-forget, because it is derived and can be rebuilt. This
  one is not derived — it IS the record. `claim/3` and `release/3` return errors
  and the caller must fail the operation on one.

  The converse cannot be enforced here: a claim that lands against a row write
  that then fails is durable, because a CRDT op cannot join the transaction the
  row write runs in. Callers narrow that window by validating first, and report
  what is left through `Engram.Notes`' `:orphan_claim` counter rather than
  hiding it.

  ## Call it OUTSIDE a transaction

  `CrdtIndexPersistence.load_doc/2` and `persist_doc/3` go through
  `Repo.with_tenant/2`, which JOINS an in-flight transaction. Claiming inside
  one therefore makes the snapshot write roll back with the caller while the
  live-room write survives — the same call having different durability
  depending on whether the user happens to have a socket open. Callers claim
  before they open their transaction.

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

  ## Telemetry

      [:engram, :crdt, :index_claim]
        measurements: %{count: 1, entries: n}
        metadata:     %{op: :claim | :release,
                        route: :room | :snapshot | :recheck,
                        phase: :ok | :conflict | :rotation | :room_exit |
                               :load_failed | :persist_failed}

  This is the WRITE side of the authority that `CrdtIndexPersistence` and
  `ProjectVaultIndex` read from, and both argue in their own moduledocs that an
  unobserved subsystem is indistinguishable from an idle one. A vault where
  every rename is refused mid-rotation must not look identical to a vault nobody
  renamed.
  """
  alias Engram.Crypto.RotationGate
  alias Engram.Logger.Metadata
  alias Engram.Notes.{CrdtIndexDoc, CrdtIndexPersistence}
  alias Yex.Sync.SharedDoc

  require Logger

  @event [:engram, :crdt, :index_claim]

  # Tags every server-originated update so a client can tell our writes from
  # another device's, and so the whole batch arrives as ONE transaction.
  @origin "engram_server"

  @typedoc "A path claim: this note now lives here."
  @type claim :: {path :: String.t(), note_id :: String.t()}

  @doc """
  Claim `entries` (`[{path, note_id}]`) for their notes.

  Applied as one Yjs transaction, so a folder cascade or a batch move reaches
  observers as a single update rather than 2N. Any other entry naming one of
  these notes is dropped, which is what makes a claim a MOVE rather than a copy.

  Returns `{:error, :conflict}` if a target path is held by a different note, or
  if two entries in the SAME call name one path — the whole batch is refused
  either way. Remember this only sees the MAP; see "The map cannot enforce
  uniqueness on its own".
  """
  @spec claim(map(), String.t(), [claim()]) :: :ok | {:error, term()}
  def claim(user, vault_id, entries)

  def claim(_user, _vault_id, []), do: :ok

  def claim(user, vault_id, entries) when is_map(user) do
    apply_targets(user, vault_id, Enum.map(entries, fn {path, id} -> {id, path} end), :claim)
  end

  @doc """
  Drop every entry naming any of `note_ids` — the note is gone.

  Idempotent: releasing a note with no entries is a no-op, not an error.

  A LOST release is not just noise. The stale entry keeps naming a dead note, so
  `claim/3` refuses that path for every live note forever, even though the rows
  are free — a deleted file becomes a permanent path reservation.
  """
  @spec release(map(), String.t(), [String.t()]) :: :ok | {:error, term()}
  def release(user, vault_id, note_ids)

  def release(_user, _vault_id, []), do: :ok

  def release(user, vault_id, note_ids) when is_map(user) do
    apply_targets(user, vault_id, Enum.map(note_ids, &{&1, :gone}), :release)
  end

  # ONE fallback, never a loop. An earlier shape had `via_room` fall back to
  # `via_snapshot` and `via_snapshot` re-enter `via_room` through
  # `recheck_room`. Against a room that is ALIVE but unresponsive — a
  # `GenServer.call` timeout exits the caller too, it is not only `:noproc` —
  # that recursed without bound, at 5s plus a full snapshot decrypt/re-encrypt
  # per lap. Routing is decided once, here.
  defp apply_targets(user, vault_id, targets, op) do
    # Checked HERE, before routing, not inside the snapshot path. It used to sit
    # in `do_via_snapshot`, which meant it could never fire for a vault with a
    # live index room — i.e. never for a connected user. That is exactly
    # inverted: the gap it exists to expose is "durability differs depending on
    # whether a socket is open", and the room route is the open-socket half.
    warn_if_in_transaction(user, vault_id, op)

    case :global.whereis_name({:crdt_index, vault_id}) do
      pid when is_pid(pid) ->
        case via_room(pid, targets) do
          {:error, {:room_exit, _}} = err ->
            # The room died or stopped answering. Its checkpoint may or may not
            # have run, so the snapshot is the only place left to write.
            emit(op, :room, :room_exit, targets)
            log(user, vault_id, op, "index room unavailable: #{sanitize(err)}")
            via_snapshot(user, vault_id, targets, op)

          # Same treatment, different cause. A remote room whose copy of this
          # module was compiled from different source cannot invoke the closure
          # we shipped it — funs travel as {module, md5, index} — which is live
          # during every rolling deploy. Losing the claim outright over a deploy
          # window is worse than writing the snapshot.
          {:error, :mailbox_empty} ->
            emit(op, :room, :mailbox_empty, targets)
            log(user, vault_id, op, "room gave no answer; falling back to snapshot")
            via_snapshot(user, vault_id, targets, op)

          result ->
            emit(op, :room, phase(result), targets)

            case result do
              :ok -> :ok
              other -> log(user, vault_id, op, "room write refused: #{sanitize(other)}")
            end

            result
        end

      :undefined ->
        via_snapshot(user, vault_id, targets, op)
    end
  end

  # `update_doc/2` returns :ok and DISCARDS the fun's value, so a refusal has to
  # be posted back out of the room process.
  #
  # `after 0` is deliberate and is NOT a race: `handle_call({:update_doc, fun})`
  # runs the fun and only then replies, so when this call returns the message is
  # already in the mailbox. An earlier version used `after 5_000`, which was
  # unreachable — the enclosing `GenServer.call` has its own 5s timeout and
  # exits first. `:mailbox_empty` therefore means a y_ex contract change, and
  # should fail loudly rather than masquerade as a slow room.
  defp via_room(room, targets) do
    caller = self()
    ref = make_ref()

    SharedDoc.update_doc(room, fn doc -> send(caller, {ref, mutate(doc, targets)}) end)

    receive do
      {^ref, result} -> result
    after
      0 -> {:error, :mailbox_empty}
    end
  catch
    # Broad, but never silent — the caller logs `reason` before falling back.
    # This catches `:noproc` (room gone between the lookup and the call), a
    # `:timeout` from an overloaded or cross-node room, AND `mutate/2` raising
    # inside the room process, which kills the room for every client on that
    # vault. Those must not be reduced to an anonymous slow request.
    #
    # KNOWN GAP on the timeout case: the room still has our message queued and
    # will apply it later, while we go on to mutate the persisted snapshot. Two
    # divergent decisions from one call, resolved by whichever writes last.
    # Narrowing this needs a claim token y_ex does not offer today.
    :exit, reason ->
      {:error, {:room_exit, reason}}
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
  #
  # Matching `:ok` EXPLICITLY, not `_`. This gate stands between a write and
  # permanent unreadability; a future third return from `check_user/1` must
  # break the build here rather than silently open it.
  defp via_snapshot(user, vault_id, targets, op) do
    case rotation_gate(user) do
      :ok ->
        do_via_snapshot(user, vault_id, targets, op)

      {:error, :rotation_in_progress} = err ->
        emit(op, :snapshot, :rotation, targets)
        log(user, vault_id, op, "refused — dek rotation in progress")
        err
    end
  end

  # `RotationGate.check_user/1` only has clauses for `%User{}`, while every
  # caller's published spec here says `map()`. Anything else FAILS CLOSED rather
  # than crashing or, worse, proceeding: this gate stands between a write and
  # permanent unreadability, so "I cannot tell whether a rotation is running"
  # must mean "do not write".
  defp rotation_gate(user) when is_struct(user, Engram.Accounts.User),
    do: RotationGate.check_user(user)

  defp rotation_gate(_other), do: {:error, :rotation_in_progress}

  defp do_via_snapshot(user, vault_id, targets, op) do
    with {:ok, doc} <- CrdtIndexPersistence.load_doc(user, vault_id),
         :ok <- mutate(doc, targets),
         :ok <- CrdtIndexPersistence.persist_doc(user, vault_id, doc) do
      emit(op, :snapshot, :ok, targets)
      recheck_room(user, vault_id, targets, op)
    else
      {:error, :conflict} = err ->
        emit(op, :snapshot, :conflict, targets)
        err

      {:error, reason} = err ->
        emit(op, :snapshot, snapshot_phase(reason), targets)
        log(user, vault_id, op, "snapshot write failed: #{sanitize({:error, reason})}")
        err
    end
  end

  # See "Call it OUTSIDE a transaction". No caller should trip this any more, so
  # it is a TRIPWIRE for a future call site rather than a known gap.
  #
  # Getting here used to be routine and the comment named only ONE offender.
  # There were three: `batch_move_folders/4` (which dropped its batch-wide
  # transaction) plus both folder-DELETE paths, `Engram.Folders.delete/4` and
  # `batch_delete_folders/3`, whose releases now go through
  # `Engram.Workers.ReleaseIndexEntries` so they run after the commit instead of
  # inside it.
  #
  # It warns rather than refuses because a write reaching here has already been
  # validated by its caller; refusing would turn a durability question into a
  # failed user operation.
  defp warn_if_in_transaction(user, vault_id, op) do
    if Engram.Repo.in_transaction?() do
      # A DISTINCT event. Folding this into `index_claim` polluted `count` with
      # a non-outcome and zeroed `entries`, so the two measurements disagreed by
      # construction.
      :telemetry.execute([:engram, :crdt, :index_in_transaction], %{count: 1}, %{op: op})
      log(user, vault_id, op, "ran inside a transaction — durability is not guaranteed")
    end

    :ok
  end

  defp snapshot_phase(reason) when reason in [:decrypt_failed, :corrupt_snapshot],
    do: :load_failed

  defp snapshot_phase(_reason), do: :persist_failed

  # NARROWS — does not close — the read-modify-write race: a room can bind the
  # OLD snapshot while we are between our read and our write, and its `unbind`
  # REPLACES the row rather than merging it, discarding the claim. Re-applying
  # through a room that appeared meanwhile is safe because `mutate` is
  # idempotent (it asserts "this id lives at this path").
  #
  # Residual: a room that binds AND exits entirely inside that window still
  # clobbers the claim, because our lookup then returns `:undefined`.
  #
  # This is NOT the residual risk `CrdtIndexPersistence` documents — that one is
  # a netsplit heal. This race is written down only here.
  #
  # The result is DISCARDED on purpose. The snapshot write already succeeded, so
  # the claim is durable and the caller must not be told it failed; a refusal
  # here means a client wrote a competing entry, which projection reconciles.
  # Returning it would also mean reporting failure after committing.
  defp recheck_room(user, vault_id, targets, op) do
    case :global.whereis_name({:crdt_index, vault_id}) do
      pid when is_pid(pid) ->
        result = via_room(pid, targets)

        # A DISTINCT event, not another `index_claim`. `do_via_snapshot` already
        # emitted the outcome for this claim; counting again here made a single
        # logical claim register 2-4 times, and made a `phase` breakdown report
        # the same claim as both :ok and :conflict.
        :telemetry.execute(
          [:engram, :crdt, :index_recheck],
          %{count: 1},
          %{op: op, phase: phase(result)}
        )

        case result do
          :ok -> :ok
          other -> log(user, vault_id, op, "recheck after snapshot write: #{sanitize(other)}")
        end

        :ok

      :undefined ->
        :ok
    end
  end

  # ONE Yjs transaction for the whole batch: without it every `set`/`delete`
  # auto-commits and a 200-note folder cascade broadcasts ~400 frames, letting an
  # observer read the map with a note deleted from its old path and not yet set
  # at its new one.
  defp mutate(doc, targets) do
    map = Yex.Doc.get_map(doc, CrdtIndexDoc.map_name())
    current = Yex.Map.to_map(map)

    case refusal(current, targets) do
      nil ->
        Yex.Doc.transaction(doc, @origin, fn ->
          Enum.each(targets, fn {note_id, path} ->
            stale = stale_entries(current, note_id, path)
            Enum.each(stale, fn {key, _value} -> Yex.Map.delete(map, key) end)

            if path != :gone do
              Yex.Map.set(map, path, entry(current, stale, path, note_id))
            end
          end)
        end)

        :ok

      _path ->
        {:error, :conflict}
    end
  end

  # A claim is refused when the path is held by a note OUTSIDE this batch, or
  # when two entries INSIDE it name the same path. Both produce the same
  # unrecoverable state if allowed through.
  #
  # Displacing deadlocks: the loser's entry is overwritten, leaving it
  # unclaimed — and projection is additive-corrective, so it never acts on a
  # note the map does not mention. The loser's ROW therefore never moves, never
  # releases the row-level unique constraint it holds, and the winner can never
  # derive either. Both notes stuck, permanently.
  #
  # The intra-batch half is not hypothetical: `batch_move_notes/4` moving two
  # same-basename notes from different folders into one target generates exactly
  # it, and the row-level `{:conflict, id}` backstop cannot undo a claim.
  defp refusal(current, targets) do
    occupied_by_another(current, targets) || duplicate_target(targets)
  end

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

  defp duplicate_target(targets) do
    targets
    |> Enum.flat_map(fn
      {_note_id, :gone} -> []
      {_note_id, path} -> [path]
    end)
    |> Enum.frequencies()
    |> Enum.find_value(fn {path, count} -> if count > 1, do: path end)
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

  defp phase(:ok), do: :ok
  defp phase({:error, :conflict}), do: :conflict
  defp phase({:error, :mailbox_empty}), do: :mailbox_empty
  defp phase({:error, {:room_exit, _}}), do: :room_exit
  # Only reached from the snapshot route; the room route's shapes are all
  # matched above. Labelling a room failure `:persist_failed` sent an operator
  # hunting a DB or encryption fault on a path that never touched the snapshot.
  defp phase({:error, _}), do: :persist_failed

  defp emit(op, route, phase, targets) do
    :telemetry.execute(
      @event,
      %{count: 1, entries: length(targets)},
      %{op: op, route: route, phase: phase}
    )

    :ok
  end

  # Reduce a failure to a bounded TAG before it reaches a log message.
  #
  # `inspect(exit_reason)` is not safe here. `mutate/2` calls Yex.Map.set/delete
  # with the plaintext path as an argument, and those are NIF-backed: a :badarg
  # puts the full argument list in the top stacktrace frame, so inspecting the
  # exit reason would render the path itself. `RedactFilter` scrubs metadata but
  # explicitly NOT `event.msg`, so that lands in Loki in cleartext. A Postgrex
  # error would likewise inspect the encrypted snapshot blob as a bind param.
  defp sanitize({:error, {:room_exit, {:timeout, _}}}), do: "room_exit:timeout"
  defp sanitize({:error, {:room_exit, :noproc}}), do: "room_exit:noproc"
  defp sanitize({:error, {:room_exit, _}}), do: "room_exit:other"
  defp sanitize({:error, reason}) when is_atom(reason), do: to_string(reason)
  defp sanitize({:error, {tag, _, _}}) when is_atom(tag), do: to_string(tag)
  defp sanitize({:error, {tag, _}}) when is_atom(tag), do: to_string(tag)
  defp sanitize(_), do: "unknown"

  # Never the path: `RedactFilter` scrubs metadata but explicitly NOT
  # `event.msg`. Same rule as `ProjectVaultIndex`.
  defp log(user, vault_id, op, message) do
    Logger.warning(
      "crdt index #{op} #{message}",
      Metadata.with_category(:warning, :sync, user_id: user.id, vault_id: vault_id)
    )

    :ok
  end
end
