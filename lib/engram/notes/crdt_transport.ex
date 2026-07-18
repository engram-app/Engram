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
  alias Engram.Notes.{CrdtBridge, CrdtPersistence, CrdtRegistry, CrdtUpdateLog, Note}
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
  Map every note in the vault to its decrypted `path` and head marker so a
  client can (a) diff against its local per-note heads to learn which cold
  notes advanced AND (b) DISCOVER + place a never-seen note from the head map
  alone — no `/manifest` or `note_changed` round-trip needed for discovery.

  Reads the persisted `crdt_head` column (O(notes) cheap row reads, NO doc
  rebuilds) and DECRYPTS each note's Phase-B `path_ciphertext` server-side with
  the caller's DEK — the same per-path AES-GCM decrypt `/manifest` pays. Path
  payloads decrypt in ~µs each; the added cost is bounded per-vault and matches
  the manifest's, so this is no longer a pure column read.

  The `crdt_head` column is NULLed on every CRDT-state change (`update_v1` on a
  tail append; a `crdt_state_ciphertext` trigger on any snapshot write), and a
  NULL is self-healed once here via `backfill_head/3`; the `BackfillCrdtHead`
  worker warms NULLs in the background so a live poll rarely pays that cost. So
  steady-state head cost is O(notes changed since the last poll), not O(vault).

  A note whose path is missing/undecryptable is SKIPPED (logged), never fatal —
  one bad row must not sink the whole vault head map. No DEK (brand-new user,
  zero writes) → empty map, same short-circuit `/manifest` uses.

  Returns `heads_map`. A note whose path is missing/undecryptable is SKIPPED
  (logged), never fatal — one bad row is dropped and the vault map survives, to
  be caught next poll. This feed's only consumer is the non-destructive REST
  `GET /vault/heads` discovery path, which ignores completeness. (The old
  `{heads, complete}` completeness contract — a `false` flag that gated a
  destructive offline-delete reconcile — was dropped with the `crdt_catchup_heads`
  socket handler in the REST-purge Phase E; nothing consumed the flag.)
  """
  @spec vault_heads(map(), map()) ::
          %{String.t() => %{path: String.t(), head: String.t()}}
  def vault_heads(user, vault) do
    case Crypto.get_dek(user) do
      {:ok, dek} -> vault_heads_with_dek(user, vault, dek)
      # No DEK (brand-new user, zero writes) → empty map, same short-circuit
      # `/manifest` uses.
      {:error, :no_dek} -> %{}
    end
  end

  defp vault_heads_with_dek(user, vault, dek) do
    {:ok, rows} =
      Repo.with_tenant(user.id, fn ->
        Note
        |> where(
          [n],
          n.vault_id == ^vault.id and n.user_id == ^user.id and is_nil(n.deleted_at) and
            n.kind == "note"
        )
        |> select([n], {n.id, n.crdt_head, n.dek_version, n.path_ciphertext, n.path_nonce})
        |> Repo.all()
      end)

    Enum.reduce(rows, %{}, fn {note_id, crdt_head, dek_version, path_ct, path_nonce}, acc ->
      # Path first: it's the cheap guarded decrypt, and a bad path skips the note
      # BEFORE the expensive head self-heal (whose load_doc would itself raise on
      # the same corrupt row). One bad row is dropped, the vault map survives.
      with {:ok, path} <- decrypt_row_path(note_id, dek_version, path_ct, path_nonce, dek),
           {:ok, head} <- resolve_head(user, vault, note_id, crdt_head) do
        Map.put(acc, note_id, %{path: path, head: head})
      else
        _ -> acc
      end
    end)
  end

  # A warmed head passes through; a NULL is self-healed once (a deleted-note
  # race returns :not_found → drop it from the map).
  defp resolve_head(_user, _vault, _note_id, head) when is_binary(head), do: {:ok, head}

  defp resolve_head(user, vault, note_id, nil) do
    case backfill_head(user, vault, note_id) do
      {:ok, head} -> {:ok, head}
      {:error, :not_found} -> :skip
    end
  end

  # Decrypt one note's path with the same AAD scheme /manifest uses (v ≥ 2 rows
  # are AAD-bound to "notes:path:<id>"; legacy v = 1 rows decrypt with empty
  # AAD). Unlike /manifest this NEVER raises: a missing/undecryptable path is
  # logged and the note is skipped from the head map, so one corrupt row can't
  # sink the whole vault's discovery feed.
  defp decrypt_row_path(note_id, _dek_version, nil, _nonce, _dek) do
    Logger.warning(
      "vault_heads: note has no path ciphertext, skipping",
      Metadata.with_category(:warn, :sync, note_id: note_id)
    )

    :error
  end

  defp decrypt_row_path(note_id, dek_version, path_ct, path_nonce, dek) do
    aad = path_aad(note_id, dek_version)

    case Crypto.Envelope.decrypt(path_ct, path_nonce, dek, aad) do
      {:ok, path} ->
        {:ok, path}

      :error ->
        Logger.warning(
          "vault_heads: note path decrypt failed, skipping",
          Metadata.with_category(:warn, :sync, note_id: note_id)
        )

        :error
    end
  end

  # v ≥ 2 rows are AAD-bound to "notes:path:<id>"; legacy v = 1 rows used empty
  # AAD. Mirrors SyncController.manifest's path_aad/3.
  defp path_aad(note_id, dek_version) when is_integer(dek_version) and dek_version >= 2,
    do: Crypto.aad_for_row(:notes, :path, note_id)

  defp path_aad(_note_id, _dek_version), do: <<>>

  @doc """
  Rebuild a note's doc once, compute its head marker, persist it to the
  `crdt_head` column, and return it. The self-heal path for a NULL column
  (pre-migration notes, or notes never CRDT-written since the column landed).

  Shared by `vault_heads/2`' inline self-heal and the `BackfillCrdtHead` worker
  so the O(doc-rebuild) cost is paid at most once per note. The head equals what
  `read_delta/4` computes for the same state (both are sha256 of the same state
  vector), so self-healed heads never disagree with the transport's own.

  CONCURRENCY: the tail high-watermark is snapshotted BEFORE the rebuild, and
  the write is a compare-and-set (`store_head_if_unchanged/4`). A room edit that
  lands after this reads the tail appends a row and — finding `crdt_head` already
  NULL — no-op-invalidates; without the CAS this self-heal could clobber that
  NULL with a now-stale head (silent missed cold-sync). If the tail advanced, we
  leave the column NULL and the next poll re-heals. Returns `{:error, :not_found}`
  if the note was deleted between selection and rebuild.

  No @spec: the `BackfillCrdtHead` worker calls this with concrete
  `%User{}`/`%Vault{}`, so a hand-written `map()/map()` contract is a supertype
  of what Dialyzer infers (contract_supertype) — same reason `load_doc/3` omits
  its spec.
  """
  def backfill_head(user, vault, note_id) do
    watermark = tail_watermark(user, note_id)

    case load_doc(user, vault, note_id) do
      {:ok, doc} ->
        head = head_marker(doc)
        _ = store_head_if_unchanged(user, note_id, head, watermark)
        {:ok, head}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Latest tail-row id for the note (uuidv7 → time-ordered, unique, monotonic on
  append; falls to a lower value / '' on prune). Captured BEFORE a rebuild so
  `store_head_if_unchanged/4` can detect a tail that advanced under it. Public
  for the CAS regression tests. (No @spec — see backfill_head/3.)
  """
  def tail_watermark(user, note_id) do
    {:ok, wm} =
      Repo.with_tenant(user.id, fn ->
        Repo.one(
          from l in CrdtUpdateLog,
            where: l.note_id == ^note_id,
            select: fragment("coalesce(max(?::text), '')", l.id)
        )
      end)

    wm
  end

  @doc """
  Persist the head ONLY if the column is still NULL (don't overwrite a peer
  self-heal) AND the tail hasn't advanced since `watermark` was taken (don't
  persist a head computed from a now-stale tail). A losing CAS leaves NULL for
  the next poll — bounded one-poll staleness instead of a persisted stale head.
  Returns `{:ok, {count, nil}}` (count is 0 when the CAS rejects). Public for
  the CAS regression tests. (No @spec — see backfill_head/3.)
  """
  def store_head_if_unchanged(user, note_id, head, watermark) do
    Repo.with_tenant(user.id, fn ->
      from(n in Note,
        where:
          n.id == ^note_id and n.kind == "note" and is_nil(n.crdt_head) and
            fragment(
              "(SELECT coalesce(max(id::text), '') FROM crdt_update_log WHERE note_id = ?) = ?",
              n.id,
              ^watermark
            )
      )
      |> Repo.update_all(set: [crdt_head: head])
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
