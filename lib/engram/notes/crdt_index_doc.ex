defmodule Engram.Notes.CrdtIndexDoc do
  @moduledoc """
  Per-VAULT index document room (#1150), the substrate for making note identity
  a CRDT instead of a REST projection (engram-app/engram-workspace#167).

  Identity today lives in three places that must agree: `NoteIdMap` in the
  client, the REST manifest, and the seq cursor. `docs/context/relay-pattern-audit.md`
  traces every drift incident to that split. Relay has no such class because
  identity converges through the SAME channel as content — a `Y.Map` inside a
  synced doc. This room is that map.

  Doc shape: one `Y.Map` named `filemeta_v0`, `path -> %{note_id, type, hash}`.
  One room per vault rather than per note, so this *improves* the `:global`
  registration concern in #896 rather than worsening it.

  ## Deliberately inert

  The room exists, syncs and can be observed. Nothing writes to it and nothing
  depends on it. Checkpoint/projection is #1151; client adoption is
  Engram-obsidian#362/#363.

  ## Why there is no idle drain here

  Note rooms opt into the #1152 drain safely because `terminate/2` runs
  `CrdtPersistence.unbind/3`, which checkpoints before the room goes away. The
  index room has **no persistence at all** until #1151
  (`CrdtIndexPersistence` is a no-op), so a drain would exit it and take the
  entire index with it.

  So: **no `idle_exit_ms`, and no `CrdtCheckpointTimer`.** Wiring either before
  #1151 lands is silent index loss, and nothing in the drain's own test suite
  would catch it — the drain is correct, it just has nothing to save here.
  Residency is bounded the old way in the meantime (`auto_exit` on last
  observer), which is adequate precisely because the room holds nothing durable.
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
      restart: :temporary
    }
  end
end
