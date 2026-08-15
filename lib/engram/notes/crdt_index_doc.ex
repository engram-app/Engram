defmodule Engram.Notes.CrdtIndexDoc do
  @moduledoc """
  Per-VAULT index document room (#1150), the substrate for making note identity
  a CRDT instead of a REST projection (engram-app/engram-workspace#167).

  Identity today lives in three places that must agree: `NoteIdMap` in the
  client, the REST manifest, and the seq cursor. `relay-pattern-audit.md` (engram-workspace repo)
  traces every drift incident to that split. Relay has no such class because
  identity converges through the SAME channel as content — a `Y.Map` inside a
  synced doc. This room is that map.

  Doc shape: one `Y.Map` named `filemeta_v0`, `path -> %{note_id, type, hash}`.
  One room per vault rather than per note, so this *improves* the `:global`
  registration concern in #896 rather than worsening it.

  ## No client writes it yet

  The room exists, syncs and can be observed, and since #1151 it PERSISTS — see
  `CrdtIndexPersistence`. What is still missing is a writer: nothing in `lib/`
  populates `filemeta_v0`, and nothing reads it back. Projection to the `notes`
  path columns and client adoption are the remaining work
  (#1151 step 2, Engram-obsidian#362/#363).

  ## Why there is still no idle drain here

  Note rooms opt into the #1152 drain safely because `terminate/2` runs
  `CrdtPersistence.unbind/3`, which checkpoints before the room goes away. As of
  #1151 this room has that too — so the drain is now *safe* here, but it is not
  *wired*, and those are different things.

  **Still no `idle_exit_ms` and no `CrdtCheckpointTimer`.** The timer is
  note-keyed: `note_id` threads through its state and its `CrdtRoomLru.touch/3`
  call, so serving this room means generalising it rather than passing an
  option. Until then residency here is bounded only by `auto_exit` on the last
  observer, which is session-length — the open item named in
  `docs/context/crdt-index-room.md`.

  """

  @map_name "filemeta_v0"

  @doc """
  The `Y.Map` name holding `path -> %{note_id, type, hash}`.

  Matches Relay's `filemeta_v0` (`SyncStore.ts:20`) on purpose: the shape is
  the part of Relay's design that removes the drift class, and keeping the name
  makes the correspondence checkable rather than folkloric.
  """
  @spec map_name() :: String.t()
  def map_name, do: @map_name

  @doc """
  Start the index room for `vault_id`, registered `{:global, {:crdt_index, id}}`.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()} | :ignore
  def start_link(opts) do
    vault_id = Keyword.fetch!(opts, :vault_id)
    user_id = Keyword.fetch!(opts, :user_id)

    Yex.Sync.SharedDoc.start_link(
      [
        doc_name: vault_id,
        # Must match CrdtBridge.new_doc/0 — UTF-16 offsets are wire-compatible
        # with Yjs JS clients; the y_ex default (:bytes) is NOT.
        doc_option: %Yex.Doc.Options{offset_kind: :utf16},
        persistence: {Engram.Notes.CrdtIndexPersistence, %{user_id: user_id, vault_id: vault_id}},
        auto_exit: true
      ],
      name: Engram.Notes.CrdtIndexRegistry.global_name(vault_id)
    )
  end

  @doc false
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :vault_id)},
      start: {__MODULE__, :start_link, [opts]},
      # :temporary for the same reason note rooms are — a restarted room would
      # have zero observers and (auto_exit being :DOWN-driven) never exit, i.e.
      # an immortal orphan. Channels re-establish it on demand.
      restart: :temporary,
      # LONGER than a note room's 15 s, not shorter, and the OTP default of
      # 5_000 is badly wrong here. A note room can afford to be brutal-killed
      # mid-flush: its encrypted tail-log still holds every update, so the next
      # bind replays it and only the work is wasted. This room has NO tail log
      # (see CrdtIndexPersistence) — a blown deadline loses every index write
      # since the last exit, permanently.
      #
      # And the deadline is harder to hit: unbind/3 does a user lookup, a full
      # doc encode, AES-GCM over a blob #1149 sizes at ~2.0 MB for a 10k-note
      # vault, and an insert_all — during a deploy stampede where every room
      # terminates at once and contends for the DB pool (#851).
      shutdown: 30_000
    }
  end
end
