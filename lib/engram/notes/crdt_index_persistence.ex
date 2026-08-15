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
  for paths, so a lost interval leaves the index STALE and rebuildable rather
  than wrong. An ungraceful room death (SIGKILL, node loss) therefore loses
  index writes since the last exit.

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
  alias Engram.Logger.Metadata
  alias Engram.Notes.VaultIndexState
  alias Engram.Repo

  require Logger

  @impl true
  def bind(%{user_id: user_id, vault_id: vault_id} = state, _doc_name, doc) do
    # Mirrors CrdtPersistence.bind/3: trapping exits makes gen_server intercept
    # the supervisor's :shutdown on a deploy and run terminate/2 -> unbind,
    # instead of dying unflushed. Guarded on :"$initial_call" so a direct bind/3
    # from a bare test process does not leak trap_exit into the test, where it
    # would swallow linked-process crashes.
    if Process.get(:"$initial_call") != nil, do: Process.flag(:trap_exit, true)

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
    # Re-read the user rather than caching one from bind/3. A room can outlive a
    # DEK rotation, and `CrdtCheckpoint` re-reads for the same reason
    # (crdt_checkpoint.ex:59): a stale struct carries the OLD wrapped dek, so
    # this write would be encrypted under a key that rotation has already swept
    # past — undecryptable the moment the old key is retired. There is no hot
    # path here to protect (no update_v1/4), so the read costs nothing.
    user = Accounts.get_user!(user_id)

    with {:ok, encoded} <- encode_state(doc, vault_id),
         {:ok, {ct, nonce}} <- Crypto.encrypt_index_state(encoded, user, vault_id) do
      upsert(user_id, vault_id, ct, nonce)
    else
      {:error, reason} ->
        # Loud: this is the write that makes the index durable at all, and the
        # room is on its way out — there is no later attempt.
        Logger.error(
          "crdt index checkpoint failed: #{inspect(reason)}",
          Metadata.with_category(:error, :sync, user_id: user_id, vault_id: vault_id)
        )
    end

    :ok
  end

  # A doc that fails to encode is NOT checkpointed as empty: overwriting a good
  # snapshot with nothing is indistinguishable from a fresh vault on the next
  # bind, and the index would come back silently empty.
  defp encode_state(doc, vault_id) do
    case Yex.encode_state_as_update(doc) do
      {:ok, encoded} when is_binary(encoded) -> {:ok, encoded}
      {:error, reason} -> {:error, {:encode_failed, reason, vault_id}}
    end
  end

  defp apply_snapshot(row, user, doc, vault_id) do
    case Crypto.decrypt_index_state(row, user) do
      {:ok, snapshot} when is_binary(snapshot) ->
        case Yex.apply_update(doc, snapshot) do
          :ok ->
            :ok

          other ->
            log_bind_failure(vault_id, {:apply_failed, other})
        end

      {:error, reason} ->
        # Bind with an EMPTY doc rather than crashing the room, but say so
        # loudly. The room stays usable; the risk is that the next checkpoint
        # overwrites a snapshot we could not read, which is why this is a
        # warning an operator is meant to see rather than a debug line.
        log_bind_failure(vault_id, reason)
    end
  end

  defp log_bind_failure(vault_id, reason) do
    Logger.warning(
      "crdt index bind could not restore the snapshot: #{inspect(reason)}",
      Metadata.with_category(:warning, :sync, vault_id: vault_id)
    )
  end

  defp upsert(user_id, vault_id, ct, nonce) do
    now = DateTime.utc_now()

    Repo.with_tenant(user_id, fn ->
      Repo.insert_all(
        VaultIndexState,
        [
          [
            vault_id: vault_id,
            user_id: user_id,
            state_ciphertext: ct,
            state_nonce: nonce,
            dek_version: Crypto.row_version_aad_bound(),
            inserted_at: now,
            updated_at: now
          ]
        ],
        on_conflict: {:replace, [:state_ciphertext, :state_nonce, :dek_version, :updated_at]},
        conflict_target: :vault_id
      )
    end)

    :ok
  end
end
