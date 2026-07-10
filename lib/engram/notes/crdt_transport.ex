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
  import Ecto.Query

  alias Engram.{Crypto, Notes, Repo}
  alias Engram.Logger.Metadata
  alias Engram.Notes.{CrdtBridge, CrdtPersistence, CrdtRegistry, Note}
  alias Yex.Sync.SharedDoc

  require Logger

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

  @doc """
  Apply a Yjs update to the canonical server doc through its live room.

  Idempotently starts the `:global` room, applies the update inside it (the
  room's persistence callback encrypts + appends it to the tail log and
  fastlanes it to live observers), and returns the new head marker.

  A malformed update yields `{:error, :invalid_update}` and mutates nothing.
  """
  @spec apply_update(map(), map(), String.t(), binary()) ::
          {:ok, %{head: String.t()}}
          | {:error, :not_found | :invalid_update | :room_unavailable}
  def apply_update(user, vault, note_id, update) do
    if Notes.note_in_vault?(user, vault.id, note_id) do
      with {:ok, room} <- CrdtRegistry.ensure_started(user.id, vault.id, note_id),
           {:ok, head} <- apply_in_room(room, note_id, update) do
        {:ok, %{head: head}}
      else
        {:error, :invalid_update} -> {:error, :invalid_update}
        # ensure_started failure, or a room that timed out / died mid-apply.
        {:error, _reason} -> {:error, :room_unavailable}
      end
    else
      {:error, :not_found}
    end
  end

  # Apply `update` to the room's doc and read the resulting head marker in the
  # SAME synchronous in-room call, so a successful return is confirmed (never a
  # false :ok from a raced timeout) and we never touch a possibly-dead pid
  # afterwards. A malformed update yields {:error, :invalid_update}; a timed-out
  # or gone room yields {:error, :room_unavailable}. Mirrors the benign-exit
  # tolerance of CrdtDeliver.room_apply/3 but, unlike that fire-and-forget path,
  # REPORTS failures instead of swallowing them — this is a write contract, not
  # best-effort delivery.
  @spec apply_in_room(pid(), String.t(), binary()) ::
          {:ok, String.t()} | {:error, :invalid_update | :room_unavailable}
  defp apply_in_room(room, note_id, update) do
    parent = self()
    ref = make_ref()

    # SharedDoc.update_doc is a synchronous GenServer.call: the fun runs to
    # completion inside the room before this returns, so the {ref, result}
    # message is already in our mailbox when we receive it.
    SharedDoc.update_doc(room, fn doc ->
      result =
        case Yex.apply_update(doc, update) do
          :ok -> {:ok, head_marker(doc)}
          {:error, _} -> {:error, :invalid_update}
        end

      send(parent, {ref, result})
      :ok
    end)

    receive do
      {^ref, result} -> result
    after
      0 -> {:error, :room_unavailable}
    end
  catch
    :exit, {:noproc, _} -> {:error, :room_unavailable}
    :exit, {:normal, _} -> {:error, :room_unavailable}
    :exit, {:shutdown, _} -> {:error, :room_unavailable}
    :exit, reason ->
      Logger.error(
        "crdt transport room apply exited",
        Metadata.with_category(:error, :sync, note_id: note_id, reason: inspect(reason))
      )

      {:error, :room_unavailable}
  end

  @doc """
  Map every note in the vault to its head marker so a client can diff against
  its local per-note heads and learn which cold notes advanced.
  """
  @spec vault_heads(map(), map()) :: %{String.t() => String.t()}
  def vault_heads(user, vault) do
    # ponytail: rebuilds every note's doc read-only — O(notes) NIF work per call,
    # and read_delta also decrypts each note's content it then discards. NO client
    # polls this in Phase 1; it is dormant until Phase 3. Upgrade path (spec open
    # Q#1): persist a `crdt_head` column updated in update_v1/checkpoint, or ETag
    # the index, before any client polls it at scale.
    {:ok, ids} =
      Repo.with_tenant(user.id, fn ->
        Note
        |> where([n], n.vault_id == ^vault.id and is_nil(n.deleted_at))
        |> select([n], n.id)
        |> Repo.all()
      end)

    Map.new(ids, fn note_id ->
      {:ok, %{head: head}} = read_delta(user, vault, note_id, nil)
      {note_id, head}
    end)
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
