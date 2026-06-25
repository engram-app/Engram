defmodule Engram.Notes.CrdtPersistence do
  @moduledoc """
  `Yex.Sync.SharedDoc.PersistenceBehaviour` impl, posture C.

  * `bind/3`  — on room start, decrypt the note's `crdt_state` snapshot and
    apply it, then replay the encrypted tail-log. The room's doc is then the
    authoritative merge of snapshot + all updates since.
  * `update_v1/4` — append each incoming update to the encrypted tail-log
    (cheap, frequent). The full snapshot is rewritten on debounced checkpoints
    (`Engram.Notes.CrdtCheckpoint`), NOT here — keeps the hot path O(append).
  * `unbind/3` — on graceful room exit (last observer disconnect with
    `auto_exit: true`), flush a compacted snapshot to the notes row. Done
    asynchronously so it does not block channel teardown.
  """
  @behaviour Yex.Sync.SharedDoc.PersistenceBehaviour

  import Ecto.Query
  alias Engram.{Accounts, Crypto, Repo}
  alias Engram.Logger.Metadata
  alias Engram.Notes.{CrdtCheckpointTimer, CrdtUpdateLog, Note}

  require Logger

  # `bind/3`'s return value becomes the `persistence_state` threaded to every
  # subsequent `update_v1/4` and `unbind/3` call. We resolve the user ONCE here
  # and cache it in the state so the per-update hot path does NOT do an
  # `Accounts.get_user!` DB round-trip on every keystroke.
  @impl true
  def bind(%{user_id: user_id, note_id: note_id} = state, _doc_name, doc) do
    user = Accounts.get_user!(user_id)

    Repo.with_tenant(user_id, fn ->
      case Repo.get(Note, note_id) do
        %Note{} = note ->
          with {:ok, snapshot} when is_binary(snapshot) <- Crypto.decrypt_crdt_state(note, user) do
            :ok = Yex.apply_update(doc, snapshot)
          end

          replay_tail(doc, user, note_id)

        nil ->
          :ok
      end
    end)

    # Cache the resolved user in the threaded state for update_v1/4 and unbind/3.
    Map.put(state, :user, user)
  end

  # Uses the user cached by bind/3 when present (the live room path); falls back
  # to a lazy fetch when called with a bare state map (direct unit-test calls).
  @impl true
  def update_v1(
        %{user_id: user_id, vault_id: vault_id, note_id: note_id} = state,
        update,
        _name,
        _doc
      ) do
    user = state[:user] || Accounts.get_user!(user_id)

    case Crypto.encrypt_crdt_state(update, user, note_id) do
      {:ok, {ct, nonce}} ->
        Repo.with_tenant(user_id, fn ->
          %CrdtUpdateLog{}
          |> CrdtUpdateLog.changeset(%{
            note_id: note_id,
            user_id: user_id,
            vault_id: vault_id,
            update_ciphertext: ct,
            update_nonce: nonce
          })
          |> Repo.insert!()
        end)

      {:error, reason} ->
        Logger.error(
          "crdt_update_log encrypt failed note_id=#{note_id} reason=#{inspect(reason)}",
          Metadata.with_category(:error, :sync, note_id: note_id)
        )
    end

    # Signal the checkpoint timer so it can debounce a snapshot flush.
    # update_v1 is called inside the room GenServer process; the timer pid
    # was stored there by CrdtDoc.start_link via Process.put(:crdt_timer_pid).
    case Process.get(:crdt_timer_pid) do
      pid when is_pid(pid) -> CrdtCheckpointTimer.notify_activity(pid)
      _ -> :ok
    end

    state
  end

  # Runs on graceful room terminate (SharedDoc `auto_exit: true`). Flushes the
  # compacted snapshot to the notes row so the next bind/3 starts from a recent
  # checkpoint rather than replaying the full tail-log. A single Postgres UPDATE
  # is fast enough to run inline — avoids a Task.start race in tests and keeps
  # the channel teardown path simple.
  @impl true
  def unbind(%{user_id: user_id, note_id: note_id} = state, _doc_name, doc) do
    user = state[:user] || Accounts.get_user!(user_id)

    case Yex.encode_state_as_update(doc) do
      {:ok, snapshot} ->
        case Crypto.encrypt_crdt_state(snapshot, user, note_id) do
          {:ok, {ct, nonce}} ->
            Repo.with_tenant(user_id, fn ->
              Repo.update_all(
                from(n in Note, where: n.id == ^note_id),
                set: [
                  crdt_state_ciphertext: ct,
                  crdt_state_nonce: nonce,
                  dek_version: Crypto.row_version_aad_bound()
                ]
              )
            end)

          {:error, reason} ->
            Logger.error(
              "crdt unbind encrypt failed note_id=#{note_id} reason=#{inspect(reason)}",
              Metadata.with_category(:error, :sync, note_id: note_id)
            )
        end

      {:error, reason} ->
        Logger.error(
          "crdt unbind encode_state_as_update failed note_id=#{note_id} reason=#{inspect(reason)}",
          Metadata.with_category(:error, :sync, note_id: note_id)
        )
    end

    :ok
  end

  defp replay_tail(doc, user, note_id) do
    CrdtUpdateLog
    |> where([l], l.note_id == ^note_id)
    |> order_by([l], asc: l.inserted_at)
    |> Repo.all()
    |> Enum.each(fn row ->
      shaped = %Note{
        id: note_id,
        dek_version: Crypto.row_version_aad_bound(),
        crdt_state_ciphertext: row.update_ciphertext,
        crdt_state_nonce: row.update_nonce
      }

      case Crypto.decrypt_crdt_state(shaped, user) do
        {:ok, upd} when is_binary(upd) ->
          Yex.apply_update(doc, upd)

        {:error, reason} ->
          Logger.warning(
            "crdt replay_tail decrypt failed note_id=#{note_id} reason=#{inspect(reason)}",
            Metadata.with_category(:warning, :sync, note_id: note_id, reason: inspect(reason))
          )

        unexpected ->
          Logger.warning(
            "crdt replay_tail unexpected decrypt result note_id=#{note_id} result=#{inspect(unexpected)}",
            Metadata.with_category(:warning, :sync,
              note_id: note_id,
              reason: "unexpected_shape"
            )
          )
      end
    end)
  end
end
