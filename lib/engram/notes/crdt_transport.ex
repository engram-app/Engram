defmodule Engram.Notes.CrdtTransport do
  @moduledoc """
  REST transport for Yjs update bytes over the canonical server Y.Doc.

  Phase 1 of the single-authority sync redesign (spec 2026-07-09). Provides the
  same lossless-merge apply path the `crdt:` channel uses, but over REST, so a
  client can flush queued CRDT ops when the channel is down and pull deltas for
  cold notes. No client consumes these yet.

  Writes go through the canonical `:global` `SharedDoc` room (its persistence
  callback encrypts + logs the update). Reads rebuild the doc read-only from the
  persisted snapshot + tail. Never span-diffs, never applies a base_hash CAS.
  """
  alias Engram.{Crypto, Notes, Repo}
  alias Engram.Notes.{CrdtBridge, CrdtPersistence}

  @doc "sha256(state vector), url-safe base64 no padding. THE head marker."
  @spec head_marker(Yex.Doc.t()) :: String.t()
  def head_marker(doc) do
    sv = Yex.encode_state_vector!(doc)
    Base.url_encode64(:crypto.hash(:sha256, sv), padding: false)
  end

  @doc """
  Return the Yjs update the client is missing plus the current head marker.

  `since_sv == nil` returns the full state; otherwise the delta after the
  client's state vector (`Yex.encode_state_as_update(doc, since_sv)`).
  """
  @spec read_delta(map(), map(), String.t(), binary() | nil) ::
          {:ok, %{update: binary(), head: String.t()}} | {:error, :not_found}
  def read_delta(user, vault, note_id, since_sv) do
    with {:ok, doc} <- load_doc(user, vault, note_id) do
      {:ok, update} =
        case since_sv do
          nil -> Yex.encode_state_as_update(doc)
          sv -> Yex.encode_state_as_update(doc, sv)
        end

      {:ok, %{update: update, head: head_marker(doc)}}
    end
  end

  # Read-only reconstruction of the canonical doc: persisted snapshot + tail
  # replay, exactly the recipe bind/3 and maybe_merge_crdt use. Spawns no room
  # and has no side effects. A decrypt/apply failure raises (loud) rather than
  # silently returning an empty doc.
  @spec load_doc(map(), map(), String.t()) :: {:ok, Yex.Doc.t()} | {:error, :not_found}
  defp load_doc(user, vault, note_id) do
    case Notes.get_note_by_id(user, vault, note_id) do
      {:ok, note} ->
        {:ok, snapshot} = Crypto.decrypt_crdt_state(note, user)
        {:ok, doc} = CrdtBridge.doc_from_state(snapshot)
        Repo.with_tenant(user.id, fn -> CrdtPersistence.replay_tail(doc, user, note_id) end)
        {:ok, doc}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end
end
