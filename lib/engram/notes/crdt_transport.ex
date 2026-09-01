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
          {:ok, %{update: binary(), head: String.t()}}
          | {:error, :not_found | :bad_since | :unreadable}
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
  # Public (@doc false) so CrdtBridge.client_count/1 shares the bounded
  # decoder instead of keeping its own unbounded reimplementation.
  @max_varuint_bytes 10
  @doc false
  @spec read_leb128_varuint(binary()) :: {:ok, non_neg_integer(), binary()} | :error
  def read_leb128_varuint(bin), do: read_leb128_varuint(bin, 0, 0, @max_varuint_bytes)

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

  `source` is attached to the room_start telemetry so a room allocated by this
  path is attributable in `engram_prom_ex_crdt_room_start_total` rather than
  landing in `:unknown` — the question #1493 is actually about.
  """
  @spec apply_update(map(), map(), String.t(), binary(), atom()) ::
          {:ok, %{head: String.t()}}
          | {:error, :not_found | :invalid_update | :room_unavailable}
  def apply_update(user, vault, note_id, update, source \\ :unknown) do
    if Notes.note_in_vault?(user, vault.id, note_id) do
      # ensure_observed (not ensure_started): registers THIS process (the
      # per-request caller) as a SharedDoc observer so the room's lifetime is
      # bounded by ours. auto_exit is :DOWN-driven — a room started via
      # ensure_started has no observer and never reaps, leaking an immortal
      # :global room + linked CrdtCheckpointTimer per distinct note_id POSTed
      # here. With an observer, when this process exits (end of request, or
      # here in tests, the spawned caller), the room checkpoints and exits
      # unless a live channel is also observing it.
      with {:ok, room} <- CrdtRegistry.ensure_observed(user.id, vault.id, note_id, source),
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

    # An explicit `try` rather than the function-level form: `ref` has to be in
    # scope in the catch clauses so they can drain a reply the room already
    # sent. The function-level `catch` cannot see body bindings at all, which is
    # what silently made that drain impossible to write.
    try do
      apply_in_room_call(room, parent, ref, update)
      drain_reply(ref)
    catch
      :exit, {:noproc, _} ->
        drain_reply(ref)

      :exit, {:normal, _} ->
        drain_reply(ref)

      :exit, {:shutdown, _} ->
        drain_reply(ref)

      :exit, reason ->
        Logger.error(
          "crdt transport room apply exited",
          Metadata.with_category(:error, :sync,
            note_id: note_id,
            reason: Metadata.safe_exit_reason(reason)
          )
        )

        drain_reply(ref)
    end
  end

  defp apply_in_room_call(room, parent, ref, update) do
    # SharedDoc.update_doc is a synchronous GenServer.call: the fun runs to
    # completion inside the room before this returns, so the {ref, result}
    # message is already in our mailbox when we receive it.
    #
    # NO explicit timeout here, deliberately, even though the channel waits on
    # this with a budget of its own (`CrdtChannel.@room_free_apply_ms`). A
    # `GenServer.call` timeout is a CALLER-side give-up, not a cancellation: the
    # room still holds the message and still runs the fun. So a short inner
    # bound cannot deliver the thing it looks like it delivers, and it costs two
    # live defects.
    #
    # First, it manufactures the failure it claims to prevent. An apply that
    # completes at 2.5s inside a 3s outer budget is a correct SUCCESS today; cap
    # the inner call at 2s and the same apply answers `doc_update_failed` while
    # the write lands anyway — and the client's fallback is a full room
    # handshake, allocating the room this frame exists to avoid, precisely when
    # the node is already slow.
    #
    # Second, it can LOSE the write. `update_doc` is a call, and y_ex drains the
    # doc monitor's `{:update_v1, ...}` self-send only from its two
    # `handle_cast` clauses ("Process update messages immediately"), never from
    # `handle_call`. So `update_v1` sits at the room's mailbox TAIL. If the
    # applier task has already exited on the inner timeout, its `:DOWN` is
    # queued AHEAD of that self-send: the room removes its last observer, hits
    # `auto_exit`, and stops with the tail-WAL append unprocessed. Nothing
    # reaches `crdt_update_log`, and `CheckpointNote` — which rebuilds from
    # snapshot + tail-log and cannot see the in-memory doc — has no row to
    # replay. `CheckpointGate`'s loss-free claim assumes every applied update
    # has a WAL row; this is the path where it does not.
    #
    # The outer `Task.yield` already bounds the channel, which is the process
    # that actually needs bounding.
    SharedDoc.update_doc(room, fn doc ->
      result =
        case Yex.apply_update(doc, update) do
          :ok -> {:ok, head_marker(doc)}
          {:error, _} -> {:error, :invalid_update}
        end

      send(parent, {ref, result})
      :ok
    end)
  end

  # The in-room fun sends `{ref, result}` BEFORE returning, and gen_server sends
  # its own call reply only after `handle_call` returns — so on a room that dies
  # in that gap the apply may have SUCCEEDED with its head already in our
  # mailbox. That message is a plain send to a raw pid with a plain `make_ref()`,
  # not a call alias, so nothing discards it. The `catch` is function-level and
  # unwinds past the receive, so every exit clause has to drain before it can
  # honestly answer `:room_unavailable` — otherwise proof of a completed write
  # sits unread while we report failure.
  defp drain_reply(ref) do
    receive do
      {^ref, result} -> result
    after
      0 -> {:error, :room_unavailable}
    end
  end

  @doc """
  Rebuild a note's doc once, compute its head marker, persist it to the
  `crdt_head` column, and return it. The self-heal path for a NULL column
  (pre-migration notes, or notes never CRDT-written since the column landed).

  Called by the `BackfillCrdtHead` worker to warm NULL columns, so the
  O(doc-rebuild) cost is paid at most once per note. The head equals what
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
  # and has no side effects.
  #
  # An unreadable snapshot answers `{:error, :unreadable}` and must NEVER
  # fabricate an empty doc — a caller reads that as "the server holds nothing"
  # and pushes a full body into it. The bare matches this replaces existed to be
  # "loud rather than silently empty"; an explicit error is equally loud without
  # requiring every caller to be crash-tolerant.
  #
  # Being TOTAL is load-bearing now: `read_delta/4` had no caller after its REST
  # route was deleted (#1088), so a raise only ever unwound into a Task. It is
  # reachable from a socket frame today, where a raise kills the channel, takes
  # `socket.assigns.rooms` and every monitor with it, and makes the client
  # re-handshake EVERY note — the room storm #1409 exists to prevent, on a loop.
  # No @spec: Dialyzer infers the concrete
  # %User{}/%Vault{} arg types from the private call sites, and a hand-written
  # map()/map() contract is a supertype of that (contract_supertype); the public
  # read_delta/2..4 specs already document the boundary types.
  # ONE flat `with`, not a `case` wrapping a `with`.
  #
  # The nested shape needed an explicit `{:error, _}` arm on the outer `case` to
  # be total, and Dialyzer rejects that arm as dead: it infers
  # `get_note_by_id/3` as returning exactly `{:ok, %Note{}} | {:error,
  # :not_found}` today. Deleting the arm to satisfy it would give up the
  # totality this function was made total FOR — `ensure_user_dek` and the KMS
  # path can grow error terms, and a CaseClauseError here kills the channel,
  # taking `socket.assigns.rooms` and every monitor with it.
  #
  # Flattened, the `else` catch-all is genuinely reachable (the decrypt and
  # decode legs contribute their own error shapes), so it is total AND has no
  # dead pattern. `:not_found` keeps its own arm because the caller
  # distinguishes it.
  defp load_doc(user, vault, note_id) do
    with {:ok, note} <- Notes.get_note_by_id(user, vault, note_id),
         {:ok, snapshot} <- Crypto.decrypt_crdt_state(note, user),
         {:ok, doc} <- CrdtBridge.doc_from_state(snapshot) do
      Repo.with_tenant(user.id, fn ->
        CrdtPersistence.replay_tail(doc, user, note_id, vault.id)
      end)

      {:ok, doc}
    else
      {:error, :not_found} -> {:error, :not_found}
      _ -> {:error, :unreadable}
    end
  end
end
