defmodule EngramWeb.CrdtChannel do
  @moduledoc """
  Base64-in-JSON Yjs sync transport (posture C, file-level), spec §12a.

  ONE topic per vault: `crdt:{user_id}:{vault_id}`. The document is
  identified by `doc_id = "{note_id}"` inside each `crdt_msg`
  payload; `b64` base64-decodes to a standard y-protocols messageSync frame.
  doc_id IS the note_id; the channel validates it belongs to the vault,
  lazily starts + observes the singleton `CrdtDoc` room per doc, and relays
  y-protocols broadcasts back out as `crdt_msg` events tagged with the
  originating `doc_id`. Auth mirrors SyncChannel.
  """

  use Phoenix.Channel

  alias Engram.Crypto.HMAC
  alias Engram.Logger.Metadata
  alias Engram.{Notes, Vaults}
  alias Engram.Notes.CrdtRegistry
  alias Engram.Notes.CrdtTransport
  alias Yex.Sync.SharedDoc

  require Logger

  # socket assigns:
  #   rooms    :: %{doc_id => %{room: pid, note_id: binary}}
  #   room_doc :: %{room_pid => doc_id}  (reverse map for broadcast routing)

  # 5 MB decoded-frame ceiling — stops a single client from flooding RDS with
  # INSERT payloads that dwarf normal Yjs updates (which are sub-KB).
  @max_frame_bytes 5_000_000

  # Base64 expands ~4/3, so a b64 string longer than this cannot decode to a
  # frame within the cap — reject before allocating the decoded copy.
  @max_b64_bytes div(@max_frame_bytes * 4, 3) + 8

  # 240 frames / 10 s ≈ 24 msg/s sustained — well above human typing speed with
  # a 2 s client debounce, and low enough to stop scripted floods.
  # Overridable via :crdt_msg_rate_limit_override (unit tests put_env it; CI/E2E
  # set it from a CI-gated env in runtime.exs). See effective_msg_limit/0 below;
  # prod never sets it and uses @msg_limit.
  @msg_limit 240
  @msg_scale_ms 10_000

  # Per-socket ceiling on distinct rooms (notes) a single connection may enroll.
  # Each room pins a server Y.Doc + checkpoint timer, so an unbounded client
  # (buggy or hostile) could STEP1 endlessly and exhaust node RAM + the DB pool.
  # ponytail: sized as a high ABUSE ceiling, not a working limit — 4096 clears a
  # 2400-note vault under today's enroll-everything client with headroom. Tighten
  # toward the real active-set (~256) once lazy enrollment is the plugin default.
  # Runtime-overridable via config so it can be lowered without a redeploy.
  @default_max_rooms 4096

  # Handshake (STEP1/STEP2) budget — separate from @msg_limit so connect-time
  # enrollment (one STEP1 per note) can never starve edit frames (the
  # 2026-07-07 incident trigger on a ~230-note vault). 2400/10s enrolls a
  # 2400-note vault inside one window; bounded, not exempt (see frame_class).
  @hs_limit 2400

  # Account-wide ceiling = @msg_limit × this. A user may run several devices,
  # each with the full per-device budget, but the account total is capped so a
  # single account can't multiply its budget without bound by opening many
  # sockets or forging device ids (the WS transport has no connect-level
  # limiter). 10 ≈ "up to ten busy devices per account" before the ceiling bites.
  @account_multiplier 10

  @impl true
  def join("crdt:" <> ids, params, socket) do
    proto = Map.get(params, "crdt_proto", 1)

    if proto < Engram.Notes.CrdtBridge.doc_schema_version() do
      {:error, %{reason: "crdt_proto_too_old", min: Engram.Notes.CrdtBridge.doc_schema_version()}}
    else
      join_authenticated("crdt:" <> ids, socket)
    end
  end

  defp join_authenticated("crdt:" <> ids, socket) do
    user = socket.assigns.current_user

    user_id_str = to_string(user.id)

    case String.split(ids, ":") do
      [^user_id_str, vid_str] ->
        case Ecto.UUID.cast(vid_str) do
          {:ok, vault_id} ->
            case Vaults.get_vault(user, vault_id) do
              {:ok, vault} ->
                case Vaults.check_api_key_access(socket.assigns[:current_api_key], vault) do
                  :ok ->
                    Logger.info(
                      "crdt join",
                      Metadata.with_category(:info, :websocket,
                        conn_id: socket.assigns[:conn_id],
                        device_id: socket.assigns[:device_id],
                        topic: socket.topic,
                        user_id: HMAC.hash_user_id(to_string(user.id))
                      )
                    )

                    {:ok, assign(socket, vault: vault, rooms: %{}, room_doc: %{})}

                  _ ->
                    {:error, %{reason: "api_key_vault_forbidden"}}
                end

              _ ->
                {:error, %{reason: "vault_not_found"}}
            end

          :error ->
            {:error, %{reason: "unauthorized"}}
        end

      _ ->
        {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_in("crdt_msg", %{"doc_id" => doc_id, "b64" => b64}, socket) do
    # Classify (O(1), first 4 b64 chars) BEFORE the rate check so sync
    # handshakes ride their own, larger bucket than edit frames: connect-time
    # enrollment fires one STEP1 (+ tiny STEP2 echo) per note, so on a
    # ~230-note vault a single per-frame budget let enrollment starve the
    # user's real edits for the whole window (2026-07-07 cross-file-overwrite
    # incident trigger). The full base64 decode runs only AFTER the limiter
    # allows the frame, so an over-budget flood is still rejected at ETS-lookup
    # cost, never at MB-scale decode cost.
    with :ok <- check_rate(socket, frame_class_b64(b64)),
         {:ok, frame} <- decode_frame(b64),
         :ok <- guard_frame(frame),
         {:ok, socket, %{room: room}} <- ensure_room(socket, doc_id) do
      SharedDoc.send_yjs_message(room, frame)
      # ACK the push. Clients attach reply handlers to distinguish delivery
      # from loss; with no ack every successful push "times out" client-side —
      # the web SPA re-handshook every open note every ~3.5s forever
      # (2026-07-14). Routed-to-room is the honest ack point: the frame is in
      # the owner process's mailbox and the room's update_v1 path persists it.
      {:reply, {:ok, %{}}, socket}
    else
      {:error, :rate_limited} ->
        {:reply, {:error, %{reason: "rate_limited"}}, socket}

      {:error, :implausible_state_vector} ->
        # A crafted syncStep1 whose state vector would OOM-abort the whole VM
        # in the y_ex NIF (P0 #989). Rejected before it reaches SharedDoc.
        log_dropped(socket, doc_id, :implausible_state_vector)
        {:reply, {:error, %{reason: "implausible_state_vector"}}, socket}

      {:error, :frame_too_large} ->
        log_dropped(socket, doc_id, :frame_too_large)
        {:reply, {:error, %{reason: "frame_too_large"}}, socket}

      {:error, :room_limit} ->
        # This socket hit the per-connection room cap (abuse backstop). Reply so
        # the client stops hammering; log_dropped emits an alertable :sync warn.
        log_dropped(socket, doc_id, :room_limit)
        {:reply, {:error, %{reason: "room_limit"}}, socket}

      {:error, :not_found} = err ->
        # Unknown note_id: the frame is undeliverable, and the SENDER is the
        # one who must act — this is the create-race cross-wire signature
        # (client keyed to an id the server never adopted, 2026-07-07). Reply
        # so the plugin can trigger its live id-map reconcile immediately
        # (ensureNoteIdMapped, plugin v1.11.22) instead of talking into the
        # void until a cold-start reconcile (#955).
        log_dropped(socket, doc_id, err)
        {:reply, {:error, %{reason: "note_not_found", doc_id: doc_id}}, socket}

      err ->
        # Surface drops rather than swallowing them silently — a dropped frame
        # (bad base64, non-UUID doc_id from a stale path-keyed client, or
        # room_unavailable) means a lost edit. These stay reply-less: a
        # non-UUID doc_id may be a cleartext path (never echo it back), and
        # the sender has no actionable heal for the others.
        log_dropped(socket, doc_id, err)
        {:noreply, socket}
    end
  end

  # These four frames carry no b64 payload, so frame_class_b64 doesn't apply —
  # they ride the :handshake lane (see check_rate/2 below). All four are
  # connect/catchup-time operations (one create/delete per note mutation, one
  # catchup call per note during enrollment), the exact shape @hs_limit was
  # sized for, and NOT the continuous edit stream @msg_limit protects — so
  # sharing that lane is intentional, not accidental reuse. They are still
  # bounded (not exempt): the 2400/10s ceiling applies same as real STEP1s.
  @impl true
  def handle_in("crdt_create", %{"doc_id" => doc_id, "path" => path}, socket) do
    with :ok <- check_rate(socket, :handshake),
         {:ok, note_id} <- cast_doc_id(doc_id),
         :ok <- validate_create_path(path) do
      user = socket.assigns.current_user
      vault = socket.assigns.vault

      case Notes.genesis_crdt_note(user, vault, note_id, path) do
        {:ok, note} ->
          {:reply, {:ok, %{doc_id: note.id}}, socket}

        {:error, :id_conflict, note} ->
          {:reply, {:error, %{reason: "id_conflict", doc_id: note.id}}, socket}

        {:error, :version_conflict, note} ->
          {:reply, {:error, %{reason: "version_conflict", doc_id: note.id}}, socket}

        {:error, {:notes_cap_reached, limit, _count}} ->
          {:reply, {:error, %{reason: "notes_cap_reached", limit: limit}}, socket}

        {:error, :recently_deleted} ->
          # Delete-wins (#970): a stale device tried to un-delete a note within
          # the delete window. The delete stands; the client trashes its local
          # copy on this reply instead of wedging on a resurrect forever.
          {:reply, {:error, %{reason: "recently_deleted"}}, socket}

        {:error, %Ecto.Changeset{}} ->
          # Covers the unique-constraint case (resurrecting a tombstoned id
          # onto a path already owned by a different live note) as well as
          # any other changeset validation failure — a clean reply either way.
          {:reply, {:error, %{reason: "create_failed"}}, socket}

        {:error, _reason} ->
          # Catch-all for the crypto/KMS error class (a first-write user whose
          # DEK wrap fails, an encrypt or filter-key error): genesis_crdt_note/4
          # can return a bare {:error, term} that matches none of the arms above.
          # Without this the case raised CaseClauseError and crashed the channel.
          # {:error, term()} is in genesis_crdt_note/4's @spec, so dialyzer sees
          # this arm as reachable (it was wrongly removed before on a lying spec).
          {:reply, {:error, %{reason: "create_failed"}}, socket}
      end
    else
      {:error, :rate_limited} -> {:reply, {:error, %{reason: "rate_limited"}}, socket}
      {:error, :bad_doc_id} -> {:reply, {:error, %{reason: "bad_doc_id"}}, socket}
      {:error, :bad_path} -> {:reply, {:error, %{reason: "bad_path"}}, socket}
    end
  end

  @impl true
  def handle_in("crdt_delete", %{"doc_id" => doc_id}, socket) do
    with :ok <- check_rate(socket, :handshake),
         {:ok, note_id} <- cast_doc_id(doc_id) do
      user = socket.assigns.current_user
      vault = socket.assigns.vault
      device_id = socket.assigns[:device_id]
      # Idempotent: a :not_found means the row is already gone — the desired
      # end state — so we still reply :ok. origin_device_id (#970) lets THIS
      # device drop its own note_changed echo of the delete.
      _ = Notes.delete_note_by_id(user, vault, note_id, origin_device_id: device_id)
      {:reply, {:ok, %{doc_id: note_id}}, socket}
    else
      {:error, :rate_limited} -> {:reply, {:error, %{reason: "rate_limited"}}, socket}
      {:error, :bad_doc_id} -> {:reply, {:error, %{reason: "bad_doc_id"}}, socket}
    end
  end

  @impl true
  def handle_in("crdt_catchup_heads", _payload, socket) do
    case check_rate(socket, :handshake) do
      :ok ->
        user = socket.assigns.current_user
        vault = socket.assigns.vault
        # `complete` is the completeness contract (see CrdtTransport.vault_heads):
        # true only when `heads` is provably the FULL live-note set. The plugin's
        # destructive offline-delete reconcile gates on it; non-destructive
        # consumers ignore it. `heads` shape is unchanged.
        {heads, complete} = CrdtTransport.vault_heads(user, vault)
        {:reply, {:ok, %{heads: heads, complete: complete}}, socket}

      {:error, :rate_limited} ->
        {:reply, {:error, %{reason: "rate_limited"}}, socket}
    end
  end

  @impl true
  def handle_in("crdt_catchup_delta", %{"doc_id" => doc_id} = payload, socket) do
    with :ok <- check_rate(socket, :handshake),
         {:ok, note_id} <- cast_doc_id(doc_id),
         {:ok, since_sv} <- decode_sv(Map.get(payload, "sv")),
         {:ok, %{update: update, head: head}} <-
           CrdtTransport.read_delta(
             socket.assigns.current_user,
             socket.assigns.vault,
             note_id,
             since_sv
           ) do
      {:reply, {:ok, %{doc_id: note_id, b64: Base.encode64(update), head: head}}, socket}
    else
      {:error, :rate_limited} -> {:reply, {:error, %{reason: "rate_limited"}}, socket}
      {:error, :bad_doc_id} -> {:reply, {:error, %{reason: "bad_doc_id"}}, socket}
      {:error, :bad_sv} -> {:reply, {:error, %{reason: "bad_sv"}}, socket}
      {:error, :bad_since} -> {:reply, {:error, %{reason: "bad_sv"}}, socket}
      {:error, :not_found} -> {:reply, {:error, %{reason: "not_found"}}, socket}
    end
  end

  # Single-path catch-up (Phase B): replay the seq-ordered op-log over the
  # socket from a client cursor. Reuses `list_changes_by_seq` — the same
  # seq-ordered, all-or-fails-on-decrypt feed `/sync/changes` serves — so each
  # op carries FULL content (not an SV-diff) and is causally complete: it can
  # never pend the way `crdt_catchup_delta` did (the e2e test_85 deaf-note bug).
  # Tombstones ride the same feed (deletes replay as ops). Paginated: the client
  # advances its cursor by `next_seq` and re-requests until `has_more` is false.
  @impl true
  def handle_in("crdt_catchup_since", payload, socket) do
    with :ok <- check_rate(socket, :handshake),
         {:ok, cursor} <- cast_cursor(Map.get(payload, "cursor_seq", 0)) do
      opts =
        case Map.get(payload, "limit") do
          n when is_integer(n) and n > 0 -> [limit: n]
          _ -> []
        end

      {:ok, %{changes: changes, has_more: has_more, next: next}} =
        Notes.list_changes_by_seq(
          socket.assigns.current_user,
          socket.assigns.vault,
          cursor,
          opts
        )

      # Tag each op with the SyncNoteChange discriminator so the client applies
      # it through the existing applySyncChange path (this feed is notes-only —
      # list_changes_by_seq excludes folders and never yields attachments).
      changes = Enum.map(changes, &Map.put(&1, :type, :note))

      next_seq =
        case next do
          {seq, _id} -> seq
          _ -> nil
        end

      {:reply, {:ok, %{changes: changes, has_more: has_more, next_seq: next_seq}}, socket}
    else
      {:error, :rate_limited} -> {:reply, {:error, %{reason: "rate_limited"}}, socket}
      {:error, :bad_cursor} -> {:reply, {:error, %{reason: "bad_cursor"}}, socket}
    end
  end

  # Channel-wide fallback (MUST stay last — Elixir matches handle_in top-down).
  # Every crdt_* frame above pattern-matches its required keys, so a frame
  # missing one (e.g. crdt_create with no "path") would otherwise raise
  # FunctionClauseError and crash the whole channel. Reply so the client learns
  # the frame was malformed instead of silently losing the socket.
  #
  # Gated on the same :handshake rate budget as every real frame above — an
  # unguarded fallback let malformed/unknown frames flood the channel outside
  # any budget.
  @impl true
  def handle_in(_event, _payload, socket) do
    case check_rate(socket, :handshake) do
      :ok -> {:reply, {:error, %{reason: "bad_frame"}}, socket}
      {:error, :rate_limited} -> {:reply, {:error, %{reason: "rate_limited"}}, socket}
    end
  end

  # nil / missing sv → full state; a present sv must be valid base64.
  defp decode_sv(nil), do: {:ok, nil}

  defp decode_sv(b64) when is_binary(b64) do
    case Base.decode64(b64) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :bad_sv}
    end
  end

  # A non-nil, non-string sv (e.g. a JSON number or list slipping past the
  # client) would otherwise raise FunctionClauseError and crash the channel.
  defp decode_sv(_), do: {:error, :bad_sv}

  # A cursor is a non-negative seq. A malformed one (string, float, negative)
  # replies bad_cursor rather than raising into a FunctionClauseError that would
  # crash the whole channel — same defensive contract as decode_sv/cast_doc_id.
  defp cast_cursor(n) when is_integer(n) and n >= 0, do: {:ok, n}
  defp cast_cursor(_), do: {:error, :bad_cursor}

  defp cast_doc_id(doc_id) do
    case Ecto.UUID.cast(doc_id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :bad_doc_id}
    end
  end

  # nil / non-binary / blank-after-trim path is rejected before it ever
  # reaches genesis_crdt_note/4 — path may be cleartext, so the reply never
  # echoes the raw value back.
  defp validate_create_path(p) when is_binary(p) do
    if String.trim(p) == "", do: {:error, :bad_path}, else: :ok
  end

  defp validate_create_path(_), do: {:error, :bad_path}

  @impl true
  def terminate(reason, socket) do
    Logger.info(
      "crdt leave",
      Metadata.with_category(:info, :websocket,
        conn_id: socket.assigns[:conn_id],
        device_id: socket.assigns[:device_id],
        topic: socket.topic,
        reason: inspect(reason)
      )
    )

    :ok
  end

  @impl true
  def handle_info({:yjs, frame, room}, socket) do
    case Map.get(socket.assigns.room_doc, room) do
      nil ->
        {:noreply, socket}

      doc_id ->
        push(socket, "crdt_msg", %{"doc_id" => doc_id, "b64" => Base.encode64(frame)})
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, socket) do
    case Map.get(socket.assigns.room_doc, pid) do
      nil ->
        {:noreply, socket}

      doc_id ->
        socket =
          socket
          |> assign(:rooms, Map.delete(socket.assigns.rooms, doc_id))
          |> assign(:room_doc, Map.delete(socket.assigns.room_doc, pid))

        {:noreply, socket}
    end
  end

  # A note_id is a non-sensitive UUID and is REQUIRED to diagnose which note
  # lost a dropped edit (redacting it under :path blocked the 2026-07-06
  # incident triage), so log a well-formed doc_id under the un-redacted
  # :note_id key. A doc_id that is NOT a UUID came from a stale path-keyed
  # client and may be a real cleartext path — keep those under the redacted
  # :path key so nothing sensitive ever leaks. The message body never carries
  # the id either way.
  defp log_dropped(socket, doc_id, reason) do
    id_meta =
      case Ecto.UUID.cast(doc_id) do
        {:ok, note_id} -> [note_id: note_id]
        :error -> [path: doc_id]
      end

    # Attribute the drop to a user + vault so a lost edit can be traced to who
    # hit it (the 2026-07-06 drops carried neither, so they were unattributable).
    attribution = [
      user_id: socket.assigns.current_user.id,
      vault_id: socket.assigns.vault.id
    ]

    Logger.warning(
      "crdt_channel: dropped crdt_msg → #{inspect(reason)}",
      Metadata.with_category(:warning, :sync, attribution ++ id_meta)
    )
  end

  # Rate-limit per DEVICE (not per account) so a single user's multiple devices
  # (desktop + laptop + web app, or two e2e Obsidian instances sharing one
  # session user) each get the full budget instead of self-DoSing against one
  # shared bucket. TWO layers:
  #
  #   1. per-device — `crdt_msg:<user_id>:<device>`. The `user_id` prefix is
  #      SERVER-derived, so the client-supplied device/conn id can only REFINE
  #      within its own tenant: it can never collide with another user's bucket
  #      (no cross-user griefing) nor spend anything but its own allowance.
  #   2. per-account ceiling — `crdt_msg:acct:<user_id>` at @account_multiplier×.
  #      Caps total account throughput so forging device ids / opening many
  #      sockets can't multiply the budget without bound.
  #
  # Both must allow. Per-device is checked first so a device that's already over
  # its own budget doesn't also consume from the account ceiling.
  # Classify WITHOUT decoding the payload: the first 4 base64 chars decode to
  # the frame's first 3 bytes. Yjs v1 wire layout (Yex.Sync doctests):
  # <<0, 0, ..>> STEP1, <<0, 1, ..>> STEP2, <<0, 2, ..>> update — all subtype
  # values < 128, so single-byte varints and the prefix match is exact.
  #
  # STEP1 is non-mutating (server just replies with a diff) and rides the
  # handshake lane unconditionally. STEP2 MUTATES the doc exactly like an
  # update (y_ex routes both into apply_update), so only SMALL STEP2 frames —
  # the near-empty echo replies connect enrollment produces in bulk — get the
  # handshake lane; a large STEP2 is a state-bearing mutation and pays the
  # edit budget. Without the size gate a client could relabel every edit as
  # STEP2 and mutate at 10x the intended cap.
  @hs_step2_max_b64 4096

  defp frame_class_b64(<<prefix::binary-size(4), _::binary>> = b64) do
    case Base.decode64(prefix) do
      {:ok, <<0, 0, _>>} -> :handshake
      {:ok, <<0, 1, _>>} when byte_size(b64) <= @hs_step2_max_b64 -> :handshake
      _ -> :edit
    end
  end

  # Shorter than 4 b64 chars cannot carry a valid handshake prefix; the edit
  # lane is the conservative default.
  defp frame_class_b64(_), do: :edit

  defp check_rate(socket, class) do
    {key_prefix, limit} =
      case class do
        # Handshakes get a 10x-larger bucket, NOT an exemption: STEP2 carries
        # full doc state, so an unbounded handshake lane would be a flood
        # vector. 2400/10s enrolls a 2400-note vault in one window while still
        # capping abuse; edits keep their own untouched budget either way.
        :handshake -> {"crdt_hs", effective_hs_limit()}
        :edit -> {"crdt_msg", effective_msg_limit()}
      end

    user_id = socket.assigns.current_user.id
    device = socket.assigns[:device_id] || socket.assigns[:conn_id] || "u"

    with {:allow, _} <-
           EngramWeb.RateLimiter.hit(
             "#{key_prefix}:#{user_id}:#{device}",
             @msg_scale_ms,
             limit,
             :other
           ),
         {:allow, _} <-
           EngramWeb.RateLimiter.hit(
             "#{key_prefix}:acct:#{user_id}",
             @msg_scale_ms,
             limit * @account_multiplier,
             :other
           ) do
      :ok
    else
      {:deny, _} -> {:error, :rate_limited}
    end
  end

  defp decode_frame(b64) when byte_size(b64) > @max_b64_bytes, do: {:error, :frame_too_large}

  defp decode_frame(b64) do
    case Base.decode64(b64) do
      {:ok, frame} when byte_size(frame) > @max_frame_bytes -> {:error, :frame_too_large}
      {:ok, frame} -> {:ok, frame}
      :error -> {:error, :bad_base64}
    end
  end

  # A syncStep1 frame carries a client state vector that reaches the y_ex NIF
  # (SharedDoc.send_yjs_message -> encode_state_as_update). A crafted vector
  # OOM-aborts the ENTIRE BEAM node, uncatchable — reuse the REST transport's
  # plausibility guard to reject it before it is applied (P0 #989). Non-step1
  # frames pass through unchanged.
  defp guard_frame(frame) do
    if CrdtTransport.safe_wire_frame?(frame), do: :ok, else: {:error, :implausible_state_vector}
  end

  # Lazily start + observe the room for `doc_id`, caching it in assigns. On the
  # first reference, validates doc_id (the note_id) belongs to the vault, then
  # calls CrdtRegistry.ensure_started and SharedDoc.observe so {:yjs, frame, room}
  # broadcasts arrive as handle_info messages in this channel process.
  defp ensure_room(socket, doc_id) do
    case Map.fetch(socket.assigns.rooms, doc_id) do
      {:ok, entry} ->
        {:ok, socket, entry}

      :error ->
        # Abuse backstop: refuse a new room once this socket already holds the max,
        # so one connection can't pin unbounded Y.Docs + pool connections. Reply-
        # carrying (see handle_in) so the client backs off. High ceiling for now.
        if map_size(socket.assigns.rooms) >= max_rooms() do
          {:error, :room_limit}
        else
          start_and_observe_room(socket, doc_id)
        end
    end
  end

  defp start_and_observe_room(socket, doc_id) do
    %{vault: vault} = socket.assigns
    user = socket.assigns.current_user

    with {:ok, note_id} <- resolve_note_id(user, vault, doc_id),
         {:ok, room} <- CrdtRegistry.ensure_observed(user.id, vault.id, note_id) do
      # Watch the room: if it dies (crash, node loss), evict it from the cache so
      # the next crdt_msg re-creates it. Without this, send_yjs_message casts to a
      # dead pid return :ok and every subsequent edit is silently dropped.
      _ref = Process.monitor(room)

      entry = %{room: room, note_id: note_id}

      socket =
        socket
        |> assign(:rooms, Map.put(socket.assigns.rooms, doc_id, entry))
        |> assign(:room_doc, Map.put(socket.assigns.room_doc, room, doc_id))

      # Announce to all OTHER clients on this vault's crdt: channel that a
      # room is now active for doc_id. Recipients send a sync-step-1 (state
      # vector) which the server answers with step-2 (the diff they're
      # missing), so any device that doesn't yet have this note gets it.
      # Carry the note's path (best-effort) so a receiver can materialize an
      # empty note live rather than waiting for the pull — matches the
      # CrdtDeliver announce contract; the plugin treats "path" as optional, so
      # a failed lookup just omits it (never crash the room-open).
      payload =
        case Notes.get_note_by_id(user, vault, note_id) do
          {:ok, %{path: path}} when is_binary(path) -> %{"doc_id" => doc_id, "path" => path}
          _ -> %{"doc_id" => doc_id}
        end

      broadcast_from!(socket, "crdt_doc_ready", payload)

      {:ok, socket, entry}
    end
  end

  # doc_id IS the note_id (client-minted UUIDv7). Validate the note exists in
  # this vault before starting/observing its room. No path_hmac indirection.
  defp resolve_note_id(user, vault, doc_id) do
    case Ecto.UUID.cast(doc_id) do
      {:ok, note_id} ->
        if Notes.note_in_vault?(user, vault.id, note_id) do
          {:ok, note_id}
        else
          {:error, :not_found}
        end

      :error ->
        {:error, :bad_doc_id}
    end
  end

  # Per-socket room ceiling. Read from config at call time (not compiled in) so
  # ops can lower it live via Application.put_env under abuse, no redeploy.
  defp max_rooms, do: Application.get_env(:engram, :max_rooms_per_socket, @default_max_rooms)

  # Both limits are overridable via app env (a cached ETS read, so per-message
  # cheap). Two writers set it, never prod:
  #   - unit tests: Application.put_env(:engram, :crdt_msg_rate_limit_override, n)
  #     (crdt_channel_test.exs) so a test need not push 241 frames.
  #   - CI/E2E release stacks: config/runtime.exs sets it from the CI-gated
  #     CRDT_MSG_RATE_LIMIT_OVERRIDE env (Engram.RuntimeConfig), because the
  #     harness's compressed workload legitimately exceeds the per-account budget.
  # Prod never sets either (CI != true, no put_env), so effective_* falls back to
  # the @constant there — the limiter stays un-weakenable in production.
  defp effective_msg_limit,
    do: Application.get_env(:engram, :crdt_msg_rate_limit_override) || @msg_limit

  defp effective_hs_limit,
    do: Application.get_env(:engram, :crdt_hs_rate_limit_override) || @hs_limit
end
