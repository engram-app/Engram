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
  # In test builds the limit is reduced via :crdt_msg_rate_limit_override (see
  # per-describe setup in crdt_channel_test.exs) so tests don't push 241 frames.
  @msg_limit 240
  @msg_scale_ms 10_000

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
    # Decode BEFORE the rate check so the frame can be classified: sync
    # handshakes (STEP1/STEP2) ride their own, larger bucket than edit frames.
    # Connect-time enrollment fires one STEP1 per note, so on a ~230-note vault
    # a single per-frame budget let enrollment starve the user's real edits for
    # the whole window (2026-07-07 cross-file-overwrite incident trigger).
    # decode_frame's size cap still rejects oversized payloads up front.
    with {:ok, frame} <- decode_frame(b64),
         :ok <- check_rate(socket, frame_class(frame)),
         {:ok, socket, %{room: room}} <- ensure_room(socket, doc_id) do
      SharedDoc.send_yjs_message(room, frame)
      {:noreply, socket}
    else
      {:error, :rate_limited} ->
        {:reply, {:error, %{reason: "rate_limited"}}, socket}

      {:error, :frame_too_large} ->
        log_dropped(socket, doc_id, :frame_too_large)
        {:reply, {:error, %{reason: "frame_too_large"}}, socket}

      err ->
        # Surface drops rather than swallowing them silently — a dropped frame
        # (bad base64 or unresolvable doc_id) means a lost edit.
        log_dropped(socket, doc_id, err)
        {:noreply, socket}
    end
  end

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
  # Yjs v1 wire layout (Yex.Sync doctests): messageType 0 = sync, then the sync
  # subtype — 0 = STEP1 (state vector), 1 = STEP2 (state), 2 = update. STEP1 and
  # STEP2 are the enrollment/catch-up handshake; everything else (updates,
  # awareness, unknown) counts as an edit frame.
  defp frame_class(<<0, 0, _::binary>>), do: :handshake
  defp frame_class(<<0, 1, _::binary>>), do: :handshake
  defp frame_class(_), do: :edit

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

  # Lazily start + observe the room for `doc_id`, caching it in assigns. On the
  # first reference, validates doc_id (the note_id) belongs to the vault, then
  # calls CrdtRegistry.ensure_started and SharedDoc.observe so {:yjs, frame, room}
  # broadcasts arrive as handle_info messages in this channel process.
  defp ensure_room(socket, doc_id) do
    case Map.fetch(socket.assigns.rooms, doc_id) do
      {:ok, entry} ->
        {:ok, socket, entry}

      :error ->
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
          broadcast_from!(socket, "crdt_doc_ready", %{"doc_id" => doc_id})

          {:ok, socket, entry}
        end
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

  # Test builds allow overriding the crdt_msg rate limit via
  # Application.put_env(:engram, :crdt_msg_rate_limit_override, n) so tests
  # do not need to push 241 frames to hit the limit. Prod always uses @msg_limit.
  # compile-time branch — the override key is structurally impossible to read in
  # non-test builds (the else clause is the only definition compiled in prod).
  if Application.compile_env(:engram, :env, :prod) == :test do
    defp effective_msg_limit do
      Application.get_env(:engram, :crdt_msg_rate_limit_override) || @msg_limit
    end

    defp effective_hs_limit do
      Application.get_env(:engram, :crdt_hs_rate_limit_override) || @hs_limit
    end
  else
    defp effective_msg_limit, do: @msg_limit
    defp effective_hs_limit, do: @hs_limit
  end
end
