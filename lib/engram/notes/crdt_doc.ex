defmodule Engram.Notes.CrdtDoc do
  @moduledoc """
  Per-note Yjs document room.

  Thin wrapper over `Yex.Sync.SharedDoc`, which implements the y-protocols
  sync + awareness handshake server-side and owns the single mutable
  `Yex.Doc` (single-owner — a yrs doc is not safe for concurrent mutation).
  One process per active note, cluster-wide singleton enforced by
  `Engram.Notes.CrdtRegistry` via `:global` name registration.

  The doc is created with `offset_kind: :utf16` (spec §12a contract 4),
  matching Yjs JS clients. Persistence is supplied via the `:persistence`
  launch param; the stub (`Engram.Notes.CrdtPersistence`) is replaced by the
  real Postgres impl in Task 7.

  A `CrdtCheckpointTimer` is started alongside each room and linked to it,
  so the timer exits when the room exits. The timer receives `:activity`
  messages via `CrdtCheckpointTimer.notify_activity/1` from the persistence
  layer's `update_v1` callback (Task 9) and debounces snapshots to at most
  once every 5 s idle / 60 s ceiling.
  """

  alias Engram.Notes.CrdtCheckpointTimer

  @doc """
  Start a room for `note_id` and its companion checkpoint timer. Opts must
  carry `:user_id` and `:vault_id` (threaded to the persistence module and
  the timer). The room is registered under `{:global, _}`.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    note_id = Keyword.fetch!(opts, :note_id)
    user_id = Keyword.fetch!(opts, :user_id)
    vault_id = Keyword.fetch!(opts, :vault_id)
    name = Engram.Notes.CrdtRegistry.global_name(note_id)

    case Yex.Sync.SharedDoc.start_link(
           [
             doc_name: note_id,
             # Must match `CrdtBridge.new_doc/0` — UTF-16 offsets are wire-compatible
             # with Yjs JS clients; the y_ex default (:bytes) is NOT.
             doc_option: %Yex.Doc.Options{offset_kind: :utf16},
             persistence:
               {Engram.Notes.CrdtPersistence,
                %{user_id: user_id, vault_id: vault_id, note_id: note_id}},
             auto_exit: true
           ],
           name: name
         ) do
      {:ok, room_pid} = result ->
        # Start the debounced checkpoint timer linked to this room. The timer
        # exits when the room exits (Process.link inside CrdtCheckpointTimer.init).
        {:ok, timer_pid} =
          CrdtCheckpointTimer.start_link(
            room_pid: room_pid,
            user_id: user_id,
            vault_id: vault_id,
            note_id: note_id
          )

        # Store the timer pid in the room's process dictionary so that
        # CrdtPersistence.update_v1 (which runs inside the room GenServer)
        # can call notify_activity/1 without a separate registry lookup.
        Yex.Sync.SharedDoc.update_doc(room_pid, fn _doc ->
          Process.put(:crdt_timer_pid, timer_pid)
        end)

        result

      error ->
        error
    end
  end

  @doc false
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :note_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end
end
