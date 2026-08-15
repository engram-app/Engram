defmodule Engram.Notes.CrdtIndexPersistence do
  @moduledoc """
  `Yex.Sync.SharedDoc.PersistenceBehaviour` for the per-vault index room
  (#1150 built the room; #1151 makes it durable).

  * `bind/3` — decrypt the vault's `filemeta_v0` snapshot and apply it, so a
    re-spun room comes back with the index it had.
  * `unbind/3` — on graceful exit (last observer leaves, `auto_exit: true`),
    encrypt the whole doc state and upsert the single `vault_index_states` row.
  * `update_v1/4` — deliberately NOT implemented. See below.

  ## Snapshot-only, and what that costs

  `CrdtPersistence` appends every update to `crdt_update_log` because a note
  room's hot path is keystrokes and losing a checkpoint interval means losing
  typing. The index's writes are rename/create/delete — orders of magnitude
  rarer — and until Engram-obsidian#363 the `notes` rows remain authoritative
  for paths, so a lost interval leaves the index STALE rather than wrong. An
  ungraceful room death (SIGKILL, node loss) therefore loses index writes since
  the last exit.

  Note what "stale" is doing here: it is safe because nothing READS the index
  yet, and because the `notes` rows still hold the paths an eventual rebuild
  would read. There is no rebuild path in `lib/` — do not read "rebuildable" as
  "a rebuild exists".

  Revisit when #363 makes the index authoritative: at that point a lost
  interval IS data loss and this needs a tail log.

  ## This is what unblocks the #1152 drain for the index room

  `CrdtIndexDoc` runs no `CrdtCheckpointTimer` and sets no `idle_exit_ms`,
  because draining a room is lossless only if something checkpoints it on the
  way out. That is now this module. Opting the index room in is a follow-up,
  not an automatic consequence — see `docs/context/crdt-index-room.md`.
  """
  @behaviour Yex.Sync.SharedDoc.PersistenceBehaviour

  alias Engram.Accounts
  alias Engram.Crypto
  alias Engram.Crypto.RotationGate
  alias Engram.Logger.Metadata
  alias Engram.Notes.VaultIndexState
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

    _ =
      Repo.with_tenant(user_id, fn ->
        case Repo.get(VaultIndexState, vault_id) do
          nil ->
            # No snapshot yet: a vault whose index room has never checkpointed.
            # The doc stays empty, which is the correct starting state.
            :ok

          %VaultIndexState{} = row ->
            apply_snapshot(row, user, doc, vault_id)
        end
      end)

    state
  end

  @impl true
  def unbind(%{user_id: user_id, vault_id: vault_id}, _doc_name, doc) do
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
        checkpoint(user, user_id, vault_id, doc)
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

  defp checkpoint(user, user_id, vault_id, doc) do
    # #1341, and the note path names THIS leg as the likeliest to race:
    # `SessionInvalidator.disconnect_user/1` fires at the TOP of a rotation, so
    # rooms start draining while the sweep is still running. A checkpoint landing
    # between sweep_vault_index_states and final_flip writes an OLD-dek snapshot
    # over a row the sweep already re-wrapped — permanently undecryptable once
    # the old key retires. Re-reading the user does NOT close this: final_flip is
    # the last phase, so get_user still answers with the old wrapped dek
    # throughout the window.
    #
    # Skipping is right even with no tail log to replay: a skipped checkpoint
    # leaves the index STALE, which this module already treats as acceptable.
    # Writing loses it outright.
    case RotationGate.check_user(user) do
      {:error, :rotation_in_progress} ->
        emit_checkpoint(:skipped_rotation)

        Logger.warning(
          "crdt index checkpoint skipped — dek rotation in progress vault_id=#{vault_id}",
          Metadata.with_category(:warning, :sync, user_id: user_id, vault_id: vault_id)
        )

        :ok

      _ ->
        write_snapshot(user, user_id, vault_id, doc)
    end
  end

  defp emit_checkpoint(phase) do
    :telemetry.execute(@checkpoint_event, %{count: 1}, %{phase: phase})
    :ok
  end

  defp write_snapshot(user, user_id, vault_id, doc) do
    with {:ok, encoded} <- encode_state(doc, vault_id),
         :ok <- check_size(encoded, vault_id),
         {:ok, {ct, nonce}} <- Crypto.encrypt_index_state(encoded, user, vault_id),
         :ok <- upsert(user, vault_id, ct, nonce) do
      emit_checkpoint(:ok)
      :ok
    else
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
  # clobbers the survivor's row. Accepted for now: nothing writes the index yet.
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
