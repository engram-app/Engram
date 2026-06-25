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
  """

  @doc """
  Start a room for `note_id`. Opts must carry `:user_id` and `:vault_id`
  (threaded to the persistence module so Task 7 can load/save the encrypted
  blob under the right DEK + tenant). Registered under `{:global, _}`.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    note_id = Keyword.fetch!(opts, :note_id)
    user_id = Keyword.fetch!(opts, :user_id)
    vault_id = Keyword.fetch!(opts, :vault_id)
    name = Engram.Notes.CrdtRegistry.global_name(note_id)

    Yex.Sync.SharedDoc.start_link(
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
    )
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
