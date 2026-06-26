defmodule EngramWeb.CrdtChannel do
  @moduledoc """
  Base64-in-JSON Yjs sync transport (posture C, file-level), spec §12a.

  ONE topic per vault: `crdt:{user_id}:{vault_id}`. The document is
  identified by `doc_id = "{vault_id}/{path}"` inside each `crdt_msg`
  payload; `b64` base64-decodes to a standard y-protocols messageSync frame.
  The channel resolves doc_id → note_id (path_hmac lookup via Notes.get_note/3),
  lazily starts + observes the singleton `CrdtDoc` room per doc, and relays
  y-protocols broadcasts back out as `crdt_msg` events tagged with the
  originating `doc_id`. Auth mirrors SyncChannel.
  """

  use Phoenix.Channel

  alias Engram.Logger.Metadata
  alias Engram.{Notes, Vaults}
  alias Engram.Notes.CrdtRegistry
  alias Yex.Sync.SharedDoc

  require Logger

  # socket assigns:
  #   rooms    :: %{doc_id => %{room: pid, note_id: binary}}
  #   room_doc :: %{room_pid => doc_id}  (reverse map for broadcast routing)

  @impl true
  def join("crdt:" <> ids, _params, socket) do
    user = socket.assigns.current_user

    user_id_str = to_string(user.id)

    case String.split(ids, ":") do
      [^user_id_str, vid_str] ->
        case Ecto.UUID.cast(vid_str) do
          {:ok, vault_id} ->
            case Vaults.get_vault(user, vault_id) do
              {:ok, vault} ->
                case Vaults.check_api_key_access(socket.assigns[:current_api_key], vault) do
                  :ok -> {:ok, assign(socket, vault: vault, rooms: %{}, room_doc: %{})}
                  _ -> {:error, %{reason: "api_key_vault_forbidden"}}
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
    with {:ok, frame} <- Base.decode64(b64),
         {:ok, socket, %{room: room}} <- ensure_room(socket, doc_id) do
      SharedDoc.send_yjs_message(room, frame)
      {:noreply, socket}
    else
      err ->
        # Surface drops rather than swallowing them silently — a dropped frame
        # (bad base64 or unresolvable doc_id) means a lost edit.
        Logger.warning(
          "crdt_channel: dropped crdt_msg doc_id=#{inspect(doc_id)} → #{inspect(err)}",
          Metadata.with_category(:warning, :sync)
        )

        {:noreply, socket}
    end
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

  # Lazily start + observe the room for `doc_id`, caching it in assigns. On the
  # first reference, resolves doc_id → note_id via path_hmac lookup, then calls
  # CrdtRegistry.ensure_started and SharedDoc.observe so {:yjs, frame, room}
  # broadcasts arrive as handle_info messages in this channel process.
  defp ensure_room(socket, doc_id) do
    case Map.fetch(socket.assigns.rooms, doc_id) do
      {:ok, entry} ->
        {:ok, socket, entry}

      :error ->
        %{vault: vault} = socket.assigns
        user = socket.assigns.current_user

        with {:ok, note_id} <- resolve_note_id(user, vault, doc_id),
             {:ok, room} <- CrdtRegistry.ensure_started(user.id, vault.id, note_id) do
          :ok = SharedDoc.observe(room)
          entry = %{room: room, note_id: note_id}

          socket =
            socket
            |> assign(:rooms, Map.put(socket.assigns.rooms, doc_id, entry))
            |> assign(:room_doc, Map.put(socket.assigns.room_doc, room, doc_id))

          {:ok, socket, entry}
        end
    end
  end

  # doc_id is "{vault_id}/{path}". Strip the vault prefix (everything before
  # the first slash) and look up the note by path via the HMAC-keyed index.
  defp resolve_note_id(user, vault, doc_id) do
    case String.split(doc_id, "/", parts: 2) do
      [_vault_prefix, path] when path != "" ->
        # Self-bootstrap a brand-new note that arrives over CRDT before any REST
        # row exists (Notes.get_or_bootstrap_note); otherwise the update is
        # dropped and the note could never be created over the CRDT path.
        case Notes.get_or_bootstrap_note(user, vault, path) do
          {:ok, note} ->
            {:ok, note.id}

          other ->
            Logger.warning(
              "crdt_channel: could not resolve/bootstrap doc_id=#{inspect(doc_id)} → #{inspect(other)}",
              Metadata.with_category(:warning, :sync)
            )

            :error
        end

      _ ->
        :error
    end
  end
end
