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
    with :ok <- check_rate(socket),
         {:ok, frame} <- decode_frame(b64),
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

  defp check_rate(socket) do
    limit = effective_msg_limit()

    case EngramWeb.RateLimiter.hit(rate_key(socket), @msg_scale_ms, limit, :other) do
      {:allow, _} -> :ok
      {:deny, _} -> {:error, :rate_limited}
    end
  end

  # Rate-limit per DEVICE, not per account. A single user's multiple devices
  # (e.g. desktop + laptop + the web app, or two e2e Obsidian instances sharing
  # one session user) must not share one budget: per-account throttling makes
  # legit multi-device editing self-DoS and silently drop frames. Per-connection
  # is also the correct granularity for a real-time message channel — a scripted
  # flood originates from ONE connection and is capped here; flooding via many
  # devices/sockets is capped at socket connect. Falls back to conn_id, then the
  # user id, for clients that send no device id.
  defp rate_key(socket) do
    scope =
      socket.assigns[:device_id] || socket.assigns[:conn_id] ||
        to_string(socket.assigns.current_user.id)

    "crdt_msg:#{scope}"
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
  else
    defp effective_msg_limit, do: @msg_limit
  end
end
