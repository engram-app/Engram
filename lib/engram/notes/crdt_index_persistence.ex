defmodule Engram.Notes.CrdtIndexPersistence do
  @moduledoc """
  `Yex.Sync.SharedDoc.PersistenceBehaviour` for the per-vault index room
  (#1150 built the room; #1151 makes it durable).

  * `bind/3` — decrypt the vault's `filemeta_v0` snapshot and apply it, so a
    re-spun room comes back with the index it had.
  * `unbind/3` — on graceful exit (last observer leaves, `auto_exit: true`),
    encrypt the whole doc state and upsert the single `vault_index_states` row.
  * `update_v1/4` — the tail append (#1391). See below.

  ## Snapshot-only, and what that costs

  `CrdtPersistence` appends every update to `crdt_update_log` because a note
  room's hot path is keystrokes and losing a checkpoint interval means losing
  typing. The index's writes are rename/create/delete — orders of magnitude
  rarer — so this stays snapshot-only. An ungraceful room death (SIGKILL, node
  loss) loses index writes since the last exit.

  **That is why `update_v1/4` exists here (#1391).** The snapshot alone was
  written only when a room exited, so anything since the last checkpoint died
  with the process — and once #1151 step 2 made the map authoritative for paths,
  that meant losing committed path CLAIMS, after which projection drags the rows
  back to the superseded snapshot. Every update is now appended to
  `vault_index_update_log`, replayed on `bind/3` after the snapshot, and pruned
  by EXACT id when a checkpoint folds it in.

  Two consequences worth knowing:

  * A claim is durable once the ROOM has processed its own update message, not
    at the instant `update_doc/2` returns — `handle_update_v1` is delivered
    asynchronously. A kill inside that window still loses the update, exactly as
    it does for note rooms.
  * The prune is by exact id and never by a timestamp range. An update appended
    between the encode and the delete is not in the snapshot, and a range prune
    would silently drop the one claim the tail exists to protect.

  There is still no rebuild path in `lib/` — do not read "rebuildable" as "a
  rebuild exists".

  ## The tail is bounded ONLY by a graceful room exit

  Note rooms bound their tail three ways — `CrdtCheckpointTimer` debounces a
  flush, `update_v1/4` can checkpoint inline under `CheckpointGate`, and
  overflow goes to the `crdt_checkpoint` Oban queue. This room has none of them
  (`CrdtIndexDoc` runs no timer and sets no `idle_exit_ms`), so residency is
  session-length and the only prune is `unbind/3`.

  So the tail grows unbounded for: a room pinned open by a long-lived observer,
  a crash loop that never reaches `terminate/2`, and every room exit during a
  DEK rotation (the checkpoint is gated, so it skips the prune too). There is no
  age sweep, no size cap and no reaper; the `on_delete: :delete_all` FKs only
  fire when the user or vault is deleted.

  Tolerable today because index writes are rename/create/delete rather than
  keystrokes, so the volume is orders of magnitude below a note tail, and
  because replay is idempotent. It stops being tolerable at the same point
  everything else here does — generalising `CrdtCheckpointTimer` off `note_id`
  is #1151 step 3, and that is what bounds this.

  ## This is what unblocks the #1152 drain for the index room

  `CrdtIndexDoc` runs no `CrdtCheckpointTimer` and sets no `idle_exit_ms`,
  because draining a room is lossless only if something checkpoints it on the
  way out. That is now this module. Opting the index room in is a follow-up,
  not an automatic consequence — see `docs/context/crdt-index-room.md`.
  """
  @behaviour Yex.Sync.SharedDoc.PersistenceBehaviour

  import Ecto.Query, only: [where: 3, order_by: 3, select: 3]

  alias Engram.Accounts
  alias Engram.Crypto
  alias Engram.Crypto.RotationGate
  alias Engram.Logger.Metadata
  alias Engram.Notes.{Enqueue, VaultIndexState, VaultIndexUpdateLog}
  alias Engram.Repo

  require Logger

  # A 10k-note index encodes to ~2.0 MB (#1149). This is a blast-radius bound,
  # not a size target: the wire takes 5 MB frames at the edit-lane rate and the
  # room has no LRU or drain, so without a ceiling a client can grow an
  # arbitrarily large PERMANENT bytea. Refusing to persist keeps the last good
  # snapshot and leaves the room working in memory, which is the safer failure.
  @max_snapshot_bytes 16_000_000

  # There is no metric on the note checkpoint path either, which is why a
  # checkpoint silently ceasing to work is only visible as the absence of log
  # lines nobody queries. This one is the ONLY thing making the index durable
  # and it runs in terminate/2, where a failure has no retry — so it gets a
  # counter. Bounded phase atoms only, never vault/user ids.
  @checkpoint_event [:engram, :crdt, :index_checkpoint]

  @impl true
  # #1391. WITHOUT this callback the room was snapshot-only: everything since the
  # last checkpoint died with the process, and since #1151 step 2 made the map
  # authoritative for paths, that is committed path CLAIMS being lost — after
  # which projection drags the rows back to the superseded snapshot.
  #
  # Failure is logged and swallowed rather than raised: this runs inside the
  # room's update handling, so raising kills the room for every client on the
  # vault and loses MORE than the one update. The snapshot at checkpoint is
  # still taken, so a dropped tail row degrades to exactly the old behaviour
  # rather than to something worse.
  def update_v1(%{user_id: user_id, vault_id: vault_id} = state, update, _name, _doc) do
    case Process.get(:index_replay_echoes, 0) do
      n when n > 0 ->
        # Our own bind replaying. Re-appending it would duplicate the tail.
        Process.put(:index_replay_echoes, n - 1)
        state

      _ ->
        do_update_v1(state, user_id, vault_id, update)
    end
  end

  defp do_update_v1(state, user_id, vault_id, update) do
    with {:ok, user} <- fetch_user(user_id),
         :ok <- append_tail(user, vault_id, update) do
      state
    else
      {:error, reason} ->
        emit_tail(:failed)

        Logger.error(
          "crdt index tail append failed: #{inspect(reason)}",
          Metadata.with_category(:error, :sync, user_id: user_id, vault_id: vault_id)
        )

        state
    end
  end

  defp fetch_user(user_id) do
    case Accounts.get_user(user_id) do
      nil -> {:error, :user_gone}
      user -> {:ok, user}
    end
  end

  # The row id is minted BEFORE encrypting because the AAD binds to it — the
  # same pre-allocation the tombstone path uses for row-id-bound AAD.
  defp append_tail(user, vault_id, update) do
    # #1341. This ENCRYPTS, so it carries the same hazard as the checkpoint, and
    # `Identity`'s "the room path needs no gate — it only mutates memory" stopped
    # being true the moment this callback existed. A row written after the sweep
    # has drained but before `final_flip` retires the old key is permanently
    # unreadable: nothing will ever re-wrap it.
    #
    # Skipping costs the claim only until the next checkpoint, which is gated
    # too and therefore leaves it in memory to be written afterwards. Writing an
    # old-dek row loses it forever.
    case RotationGate.check_user(user) do
      {:error, :rotation_in_progress} ->
        emit_tail(:skipped_rotation)
        :ok

      _ ->
        do_append_tail(user, vault_id, update)
    end
  end

  defp do_append_tail(user, vault_id, update) do
    row_id = UUIDv7.generate()

    # dek_version records the version that actually wrapped THIS row, never a
    # constant: the rotation sweep stamps the new version, so a hardcoded 2
    # would disagree with the user's after the first rotation and be believed.
    dek_version = user.dek_version || Crypto.row_version_aad_bound()

    with {:ok, {ct, nonce}} <- Crypto.encrypt_index_update(update, user, row_id) do
      {:ok, _} =
        Repo.with_tenant(user.id, fn ->
          %VaultIndexUpdateLog{}
          |> VaultIndexUpdateLog.changeset(%{
            id: row_id,
            vault_id: vault_id,
            user_id: user.id,
            update_ciphertext: ct,
            update_nonce: nonce,
            dek_version: dek_version
          })
          |> Repo.insert!()
        end)

      emit_tail(:ok)
      :ok
    end
  rescue
    # `Repo.insert!` RAISES on any DB error, and under pool starvation so does
    # the checkout itself — neither is an {:error, _} the caller's `with` could
    # catch. Unrescued they kill the room for every client on the vault, and
    # `unbind`'s checkpoint then needs the same exhausted pool, so the update is
    # lost from memory AND from the tail. `unbind/3` rescues for exactly this
    # reason (the 2026-07-09 incident); match it.
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp emit_tail(phase) do
    :telemetry.execute([:engram, :crdt, :index_tail], %{count: 1}, %{phase: phase})
    :ok
  end

  @impl true
  def bind(%{user_id: user_id, vault_id: vault_id} = state, _doc_name, doc) do
    # Mirrors CrdtPersistence.bind/3: trapping exits makes gen_server intercept
    # the supervisor's :shutdown on a deploy and run terminate/2 -> unbind,
    # instead of dying unflushed. Guarded on :"$initial_call" so a direct bind/3
    # from a bare test process does not leak trap_exit into the test, where it
    # would swallow linked-process crashes.
    if Process.get(:"$initial_call") != nil, do: Process.flag(:trap_exit, true)

    # get_user!/1 here, deliberately unlike unbind/3's get_user/1. A missing user
    # means the room must NOT start: raising fails the start, the client's frame
    # errors and it retries. unbind/3 is the opposite case — it runs during
    # teardown, where a purged user is an EXPECTED state and raising produced the
    # #954 error storm.
    user = Accounts.get_user!(user_id)

    {:ok, {snapshot_applied, replay}} =
      Repo.with_tenant(user_id, fn ->
        applied =
          case Repo.get(VaultIndexState, vault_id) do
            nil ->
              # No snapshot yet: a vault whose index room has never checkpointed.
              # The doc stays empty, which is the correct starting state.
              false

            %VaultIndexState{} = row ->
              apply_snapshot(row, user, doc, vault_id)
              true
          end

        # AFTER the snapshot, always — including when there is none. A vault
        # that has never checkpointed can still have tail rows, and those are
        # the only record of its claims (#1391).
        {applied, replay_tail(doc, user, vault_id)}
      end)

    # y_ex installs the doc update monitor BEFORE bind/3 runs
    # (`doc_server_worker.ex` monitor_update_v1 -> module.init -> bind), so every
    # `Yex.apply_update/2` above posts an `{:update_v1, ...}` to this room's own
    # mailbox and comes back through update_v1/4. Without this, binding would
    # APPEND the snapshot and the whole tail it just read back onto the tail:
    # n rows become 2n+1 every restart, each cycle also writing a row the size
    # of the entire index. On a vault whose room keeps dying — the exact case
    # the tail exists for — that is a spiral, not a leak.
    #
    # A count is sound rather than a heuristic: those messages are already in
    # the mailbox when init returns, and a mailbox is FIFO, so they are the next
    # `update_v1/4` calls this process makes. No client update can overtake them
    # because start_link has not returned yet.
    echoes = if(snapshot_applied, do: 1, else: 0) + length(replay.applied)
    Process.put(:index_replay_echoes, echoes)

    # C2: prune must never delete a row bind could not fold in. A row that fails
    # to decrypt today (a DekCache miss, a read racing a rotation) still holds a
    # claim that a later successful replay can recover — unless a checkpoint
    # deleted it in the meantime.
    Map.put(state, :unfolded_ids, replay.skipped)
  end

  @impl true
  def unbind(%{user_id: user_id, vault_id: vault_id} = state, _doc_name, doc) do
    # get_user/1, NOT the bang variant. A deleted user or a vault force-purge is
    # an EXPECTED lifecycle state here — rows go while rooms are still exiting —
    # and raising turned that into a per-room error storm during a purge
    # (#954, 2026-07-07). Skip quietly.
    #
    # Re-read rather than caching from bind/3: a room can outlive a DEK
    # rotation, and a stale struct carries the OLD wrapped dek
    # (crdt_checkpoint.ex:59 re-reads for the same reason). No hot path here to
    # protect — there is no update_v1/4 — so the read costs nothing.
    case Accounts.get_user(user_id) do
      nil ->
        :ok

      user ->
        # Rows bind could not fold in are excluded from the prune — they are
        # not in this doc, so deleting them would destroy claims a later
        # successful replay could still recover.
        checkpoint(user, user_id, vault_id, doc, Map.get(state, :unfolded_ids, []))
    end
  rescue
    # A DB failure does NOT surface as {:error, _} — Repo.insert_all RAISES, and
    # under pool starvation so does the checkout itself (the 2026-07-09 incident
    # frame). Unrescued, that escapes terminate/2 rather than reaching the
    # "loud" branch below. Both siblings guarantee unbind always returns :ok
    # (crdt_persistence.ex:264, crdt_checkpoint.ex:98); match them.
    e ->
      emit_checkpoint(:failed)

      Logger.error(
        "crdt index checkpoint raised: #{Exception.message(e)}",
        Metadata.with_category(:error, :sync, user_id: user_id, vault_id: vault_id)
      )

      :ok
  catch
    # An exit is not a raise, and `rescue` does not contain one.
    # `Yex.encode_state_as_update/1` runs through a GenServer call into the doc
    # worker (Yex.Doc.run_in_worker_process), so a dead worker or a call timeout
    # during shutdown arrives here. Escaping terminate/2 would turn a lost
    # checkpoint into an anonymous SharedDoc crash report carrying no vault_id.
    :exit, reason ->
      emit_checkpoint(:failed)

      Logger.error(
        "crdt index checkpoint exited: #{inspect(reason)}",
        Metadata.with_category(:error, :sync, user_id: user_id, vault_id: vault_id)
      )

      :ok
  end

  defp checkpoint(user, user_id, vault_id, doc, unfolded_ids) do
    # #1341, and the note path names THIS leg as the likeliest to race:
    # `SessionInvalidator.disconnect_user/1` fires at the TOP of a rotation, so
    # rooms start draining while the sweep is still running. A checkpoint landing
    # between sweep_vault_index_states and final_flip writes an OLD-dek snapshot
    # over a row the sweep already re-wrapped — permanently undecryptable once
    # the old key retires. Re-reading the user does NOT close this: final_flip is
    # the last phase, so get_user still answers with the old wrapped dek
    # throughout the window.
    #
    # Skipping is right: the tail still holds everything since the last
    # checkpoint, so a skipped checkpoint costs a replay on the next bind rather
    # than the claims themselves. Writing an old-dek snapshot loses them outright.
    case RotationGate.check_user(user) do
      {:error, :rotation_in_progress} ->
        emit_checkpoint(:skipped_rotation)

        Logger.warning(
          "crdt index checkpoint skipped — dek rotation in progress vault_id=#{vault_id}",
          Metadata.with_category(:warning, :sync, user_id: user_id, vault_id: vault_id)
        )

        :ok

      _ ->
        write_snapshot(user, user_id, vault_id, doc, unfolded_ids)
    end
  end

  defp emit_checkpoint(phase) do
    :telemetry.execute(@checkpoint_event, %{count: 1}, %{phase: phase})
    :ok
  end

  @doc """
  Hydrate a `Yex.Doc` from this vault's persisted snapshot.

  Returns an EMPTY doc when there is no snapshot yet — a vault whose index room
  has never checkpointed is not an error. A snapshot that exists and will not
  decrypt IS one, and is never silently downgraded to an empty doc: writing that
  back would replace the real index with nothing.

  Public for `Engram.Notes.Identity`, which rewrites the snapshot in place when no room
  is live. Both go through `persist_doc/3` so there is exactly one writer of the
  `vault_index_states` row.
  """
  @spec load_doc(map(), String.t()) :: {:ok, Yex.Doc.t()} | {:error, term()}
  def load_doc(user, vault_id) do
    doc = Yex.Doc.new()

    # snapshot + tail ≡ bind/3's recipe. Teaching bind/3 to replay the tail and
    # NOT this would leave the roomless reader blind to every claim made since
    # the last checkpoint — which is precisely the state an ungraceful room
    # death creates, and precisely when `Identity` takes this path because
    # `:global` has no room to find.
    #
    # The consequences of the two disagreeing are not staleness. `Identity`
    # would accept a claim on a path a tail row already holds (returning success
    # where a conflict is owed), and a release would fail to remove an entry
    # that lives only in the tail, which the next bind then replays back — one
    # permanent path reservation per note.
    Repo.with_tenant(user.id, fn ->
      with :ok <- load_snapshot_into(doc, user, vault_id) do
        _ = replay_tail(doc, user, vault_id)
        {:ok, doc}
      end
    end)
    |> case do
      {:ok, result} -> result
      other -> other
    end
  end

  defp load_snapshot_into(doc, user, vault_id) do
    case Repo.get(VaultIndexState, vault_id) do
      nil ->
        :ok

      row ->
        with {:ok, snapshot} <- Crypto.decrypt_index_state(row, user) do
          case Yex.apply_update(doc, snapshot) do
            :ok -> :ok
            _ -> {:error, :corrupt_snapshot}
          end
        end
    end
  end

  @doc """
  Encode, size-check, encrypt and upsert `doc` as this vault's snapshot.

  Does NOT enqueue projection. A claim from `Engram.Notes.Identity` is followed
  immediately by the row write in the same call, so the common case needs no
  pass. Note the ordering: under claim-first the index and the rows explicitly
  do NOT agree at the moment this returns. A claim whose row write then FAILS is
  an orphan, and `Engram.Notes` enqueues projection for that case itself rather
  than leaving it to the next room checkpoint.
  """
  @spec persist_doc(map(), String.t(), Yex.Doc.t()) :: :ok | {:error, term()}
  def persist_doc(user, vault_id, doc) do
    with {:ok, encoded} <- encode_state(doc, vault_id),
         :ok <- check_size(encoded, vault_id),
         {:ok, {ct, nonce}} <- Crypto.encrypt_index_state(encoded, user, vault_id) do
      upsert(user, vault_id, ct, nonce)
    end
  end

  defp write_snapshot(user, user_id, vault_id, doc, unfolded_ids) do
    # Read the tail ids BEFORE writing, and prune exactly those afterwards.
    #
    # Not a timestamp or "everything for this vault" range: an update appended
    # between the encode and the delete is NOT in the snapshot, and a range
    # prune would drop it — silently losing the one claim the tail exists to
    # protect. Rows that arrive after this read simply survive into the next
    # bind, where replaying an update the snapshot already contains is a no-op
    # because Yjs updates are idempotent.
    folded_ids = tail_ids(user, vault_id) -- unfolded_ids

    case persist_doc(user, vault_id, doc) do
      :ok ->
        emit_checkpoint(:ok)
        prune_tail(user, folded_ids)

        # Project the index onto the notes path columns (#1151 step 2) — in a
        # worker, never here. This runs inside terminate/2 against a shutdown
        # budget, and a projection pass is N renames, each re-encrypting a path,
        # rewriting path_hmac, repathing Qdrant points and enqueueing link
        # rewrites. Doing that in a terminating process during a deploy stampede
        # loses the checkpoint AND the projection.
        #
        # Enqueued only after the snapshot is durably written, so the worker can
        # never read a snapshot older than the doc that triggered it. Per-vault
        # `unique` collapses a storm of room exits into one job.
        _ =
          Enqueue.enqueue(
            Engram.Workers.ProjectVaultIndex.new(%{user_id: user_id, vault_id: vault_id}),
            "project_vault_index"
          )

        :ok

      {:error, reason} ->
        emit_checkpoint(:failed)

        # Loud: this is the write that makes the index durable at all, and the
        # room is on its way out — there is no later attempt.
        Logger.error(
          "crdt index checkpoint failed: #{inspect(reason)}",
          Metadata.with_category(:error, :sync, user_id: user_id, vault_id: vault_id)
        )

        :ok
    end
  end

  defp check_size(encoded, vault_id) when byte_size(encoded) > @max_snapshot_bytes,
    do: {:error, {:snapshot_too_large, byte_size(encoded), vault_id}}

  defp check_size(_encoded, _vault_id), do: :ok

  # A doc that fails to encode is NOT checkpointed as empty: overwriting a good
  # snapshot with nothing is indistinguishable from a fresh vault on the next
  # bind, and the index would come back silently empty.
  defp encode_state(doc, vault_id) do
    case Yex.encode_state_as_update(doc) do
      {:ok, encoded} when is_binary(encoded) -> {:ok, encoded}
      {:error, reason} -> {:error, {:encode_failed, reason, vault_id}}
    end
  end

  # FAIL LOUD, exactly as CrdtPersistence.bind/3 does for a note's snapshot.
  #
  # Binding an empty doc here would be the fail-OPEN choice, and with no tail
  # log it is strictly worse than it is for notes: the room comes up looking
  # like a fresh vault, and the very next unbind/3 writes that empty doc back
  # over a snapshot we merely failed to READ. A transient failure — DEK cache
  # miss, a read racing a DEK rotation — becomes permanent loss of the whole
  # index.
  #
  # Raising fails the room start instead. The client's frame errors and it
  # retries; a genuinely corrupt snapshot surfaces as a loud, repeated failure
  # rather than a vault that silently forgot every path it knew.
  # Replays every tail row for this vault, oldest first, and returns the ids
  # that actually applied. Ordered by (inserted_at, id): two appends can land
  # inside one clock tick, and the checkpoint prunes by EXACT id, so a tie must
  # not let replay and prune disagree about which rows were folded in.
  #
  # A row that will not decrypt is SKIPPED, not fatal. Yjs updates are
  # commutative and idempotent, so the rest still converge; refusing to bind
  # over one bad row would take the whole vault's index down.
  # Must be called inside the caller's `Repo.with_tenant` transaction — it
  # queries a tenant-scoped table.
  @doc false
  @spec replay_tail(Yex.Doc.t(), map(), String.t()) ::
          %{applied: [Ecto.UUID.t()], skipped: [Ecto.UUID.t()]}
  def replay_tail(doc, user, vault_id) do
    VaultIndexUpdateLog
    |> where([l], l.vault_id == ^vault_id)
    |> order_by([l], asc: l.inserted_at, asc: l.id)
    |> Repo.all()
    |> Enum.reduce(%{applied: [], skipped: []}, fn row, acc ->
      case Crypto.decrypt_index_update(row, user) do
        {:ok, update} ->
          case Yex.apply_update(doc, update) do
            :ok ->
              %{acc | applied: [row.id | acc.applied]}

            _ ->
              skip_row(acc, row, user, vault_id, :corrupt_row)
          end

        {:error, reason} ->
          skip_row(acc, row, user, vault_id, {:undecryptable_row, reason})
      end
    end)
    |> then(fn acc -> %{applied: Enum.reverse(acc.applied), skipped: acc.skipped} end)
  end

  # A skipped row is NOT dropped. It keeps its place in the tail so a later bind
  # — after the transient that caused it has cleared — can still recover the
  # claim. It is also LOGGED, not merely counted: a permanently lost path claim
  # that surfaces only as a Prometheus tick gives an operator no vault to look at.
  defp skip_row(acc, row, user, vault_id, reason) do
    phase = if is_tuple(reason), do: elem(reason, 0), else: reason
    emit_tail(phase)

    Logger.warning(
      "crdt index tail row skipped on replay: #{inspect(reason)}",
      Metadata.with_category(:warning, :sync, user_id: user.id, vault_id: vault_id)
    )

    %{acc | skipped: [row.id | acc.skipped]}
  end

  defp tail_ids(user, vault_id) do
    {:ok, ids} =
      Repo.with_tenant(user.id, fn ->
        VaultIndexUpdateLog
        |> where([l], l.vault_id == ^vault_id)
        |> select([l], l.id)
        |> Repo.all()
      end)

    ids
  end

  defp prune_tail(_user, []), do: :ok

  defp prune_tail(user, ids) do
    {:ok, {count, _}} =
      Repo.with_tenant(user.id, fn ->
        VaultIndexUpdateLog
        |> where([l], l.id in ^ids)
        |> Repo.delete_all()
      end)

    :telemetry.execute([:engram, :crdt, :index_tail], %{count: count}, %{phase: :pruned})
    :ok
  end

  defp apply_snapshot(row, user, doc, vault_id) do
    case Crypto.decrypt_index_state(row, user) do
      {:ok, snapshot} when is_binary(snapshot) ->
        :ok = Yex.apply_update(doc, snapshot)

      {:error, reason} ->
        Logger.error(
          "crdt index bind could not decrypt the snapshot: #{inspect(reason)}",
          Metadata.with_category(:error, :sync, vault_id: vault_id)
        )

        raise "crdt index bind: snapshot decrypt failed vault_id=#{vault_id} reason=#{inspect(reason)}"
    end
  end

  # REPLACES rather than merges, deliberately. Two live rooms for one vault are
  # prevented by `:global` registration, and the ordering that would matter —
  # an old room's unbind landing after a new room's bind — cannot happen either,
  # because `:global` releases the name on process death, which is strictly
  # after terminate/2 returns.
  #
  # The residual case is a netsplit heal, where `:global`'s conflict resolver
  # kills one registration and that room (trap_exit is set) runs unbind and
  # clobbers the survivor's row. This now costs committed path claims rather
  # than nothing — `Engram.Notes.Identity` writes the map — so the
  # merge-on-write fix below is load-bearing rather than optional. Still
  # accepted for now only because a netsplit heal is rare and projection
  # re-derives the rows from whichever doc survives.
  # If that changes, the fix is read-then-`Yex.apply_update`-then-encode inside
  # the same transaction — Yjs updates are commutative, so merge-then-write is
  # strictly safer than replace and costs one read on a cold path.
  #
  # Returns a result the `with` above can act on. Previously this discarded the
  # transaction result and returned a bare `:ok`, so the "loud" else-branch was
  # structurally incapable of seeing a write failure — the one failure that
  # actually costs the index. Zero rows is unreachable today (ON CONFLICT DO
  # UPDATE with no WHERE always affects one row, and an RLS WITH CHECK violation
  # raises rather than filtering), but UserDekRotation asserts the rowcount on
  # these same rows and two standards on one table is how the next person picks
  # the wrong one.
  defp upsert(user, vault_id, ct, nonce) do
    now = DateTime.utc_now()
    user_id = user.id

    result =
      Repo.with_tenant(user_id, fn ->
        Repo.insert_all(
          VaultIndexState,
          [
            [
              vault_id: vault_id,
              user_id: user_id,
              state_ciphertext: ct,
              state_nonce: nonce,
              # The version of the DEK that actually wrapped THIS blob, not a
              # constant. UserDekRotation stamps the row with the new version
              # when it re-wraps; a fixed 2 here would set it back on the next
              # checkpoint and disagree with the user's after a second rotation.
              # Nothing reads it today (decrypt_index_state/2 is unconditionally
              # AAD-bound), which is exactly why a wrong value would go unnoticed
              # until something did.
              dek_version: user.dek_version || Crypto.row_version_aad_bound(),
              inserted_at: now,
              updated_at: now
            ]
          ],
          on_conflict: {:replace, [:state_ciphertext, :state_nonce, :dek_version, :updated_at]},
          conflict_target: :vault_id
        )
      end)

    case result do
      {:ok, {1, _}} -> :ok
      {:ok, {n, _}} -> {:error, {:unexpected_row_count, n, vault_id}}
      {:error, reason} -> {:error, {:upsert_rolled_back, reason, vault_id}}
    end
  end
end
