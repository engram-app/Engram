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
  import Bitwise
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

  A `since_sv` that is valid base64 but not a real Yjs state vector (the
  controller only checks base64-ness) can hit the NIF in two different ways,
  confirmed empirically: most malformed byte sequences make it return
  `{:error, {:encoding_exception, _}}`, which we map to `{:error, :bad_since}`
  below — BUT a small, easily-crafted subset (e.g. `<<128, 128, 128, 128,
  15>>`, 5 bytes) decodes as a ~2^31-entry state vector and makes the NIF
  request a ~150 GB allocation. Rust's default OOM handler for that doesn't
  panic (catchable); it calls `abort()`, which kills the ENTIRE BEAM VM
  process — every user, every connection, not just this request. No
  try/rescue in Elixir can intercept an abort(). `plausible_state_vector?/1`
  rejects implausible shapes BEFORE the bytes ever reach the NIF, which is
  the only place this can actually be stopped.
  """
  @spec read_delta(map(), map(), String.t(), binary() | nil) ::
          {:ok, %{update: binary(), head: String.t()}} | {:error, :not_found | :bad_since}
  def read_delta(user, vault, note_id, since_sv) do
    with {:ok, doc} <- load_doc(user, vault, note_id) do
      case encode_update(doc, since_sv) do
        {:ok, update} -> {:ok, %{update: update, head: head_marker(doc)}}
        {:error, _} -> {:error, :bad_since}
      end
    end
  end

  defp encode_update(doc, nil), do: Yex.encode_state_as_update(doc)

  defp encode_update(doc, sv) do
    if plausible_state_vector?(sv) do
      Yex.encode_state_as_update(doc, sv)
    else
      {:error, :implausible_state_vector}
    end
  end

  # The y-protocols v1 state vector format is `varUint(client_count)` followed
  # by `client_count * (varUint client_id, varUint clock)`. yrs trusts the
  # decoded client_count verbatim when sizing its client map, so a state
  # vector claiming millions of entries in a handful of bytes crashes the NIF
  # (see read_delta/4 doc). Each real entry needs at least 2 bytes on the
  # wire (a 0 still costs 1 byte per varUint), so a vector claiming N clients
  # must have at least 2*N bytes left after the count header — anything
  # short of that is rejected without ever calling the NIF.
  @doc """
  True when `sv` is a plausibly-sized y-protocols v1 state vector — the
  declared client count is backed by enough remaining bytes. Guards the y_ex
  NIF against a crafted vector whose count would trigger a ~150 GB pre-alloc
  and `abort()` the whole VM. Public so the WS sync channel reuses the exact
  same check via `safe_wire_frame?/1` (P0 #989).
  """
  @spec plausible_state_vector?(binary()) :: boolean()
  def plausible_state_vector?(sv) do
    case read_leb128_varuint(sv) do
      {:ok, count, rest} -> byte_size(rest) >= count * 2
      :error -> false
    end
  end

  @doc """
  True when a decoded Yjs sync frame is safe to hand to the y_ex NIF.

  A syncStep1 frame is `<<0, 0, varUint8Array(state_vector)>>`; its embedded
  client state vector flows into `Yex.encode_state_as_update/2` — the same
  crash path `read_delta/4` guards. This unwraps the length-prefixed vector
  and validates it with `plausible_state_vector?/1`, rejecting a crafted or
  malformed step1 BEFORE it reaches the NIF. Non-step1 frames (step2 / update
  route through `apply_update`, not the vector path) are always allowed here;
  a step1 with a malformed length prefix fails closed.
  """
  @spec safe_wire_frame?(binary()) :: boolean()
  def safe_wire_frame?(<<0, 0, rest::binary>>) do
    case read_leb128_varuint(rest) do
      {:ok, sv_len, payload} when byte_size(payload) >= sv_len ->
        <<sv::binary-size(sv_len), _::binary>> = payload
        plausible_state_vector?(sv)

      _ ->
        false
    end
  end

  def safe_wire_frame?(_frame), do: true

  # LEB128 varuint reader, capped at 10 continuation bytes (enough for any
  # 64-bit value) so a run of 0x80 bytes can't loop unbounded either.
  @max_varuint_bytes 10
  defp read_leb128_varuint(bin), do: read_leb128_varuint(bin, 0, 0, @max_varuint_bytes)

  defp read_leb128_varuint(_bin, _acc, _shift, 0), do: :error
  defp read_leb128_varuint(<<>>, _acc, _shift, _budget), do: :error

  defp read_leb128_varuint(<<byte, rest::binary>>, acc, shift, budget) do
    value = bor(acc, bsl(band(byte, 0x7F), shift))

    if band(byte, 0x80) == 0 do
      {:ok, value, rest}
    else
      read_leb128_varuint(rest, value, shift + 7, budget - 1)
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
      # ensure_observed (not ensure_started): registers THIS process (the
      # per-request caller) as a SharedDoc observer so the room's lifetime is
      # bounded by ours. auto_exit is :DOWN-driven — a room started via
      # ensure_started has no observer and never reaps, leaking an immortal
      # :global room + linked CrdtCheckpointTimer per distinct note_id POSTed
      # here. With an observer, when this process exits (end of request, or
      # here in tests, the spawned caller), the room checkpoints and exits
      # unless a live channel is also observing it.
      with {:ok, room} <- CrdtRegistry.ensure_observed(user.id, vault.id, note_id),
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
    :exit, {:noproc, _} ->
      {:error, :room_unavailable}

    :exit, {:normal, _} ->
      {:error, :room_unavailable}

    :exit, {:shutdown, _} ->
      {:error, :room_unavailable}

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
        |> where(
          [n],
          n.vault_id == ^vault.id and n.user_id == ^user.id and is_nil(n.deleted_at)
        )
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
  # silently returning an empty doc. No @spec: Dialyzer infers the concrete
  # %User{}/%Vault{} arg types from the private call sites, and a hand-written
  # map()/map() contract is a supertype of that (contract_supertype); the public
  # read_delta/2..4 specs already document the boundary types.
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
