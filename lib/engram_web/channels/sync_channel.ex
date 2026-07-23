defmodule EngramWeb.SyncChannel do
  @moduledoc """
  Per-user, per-vault WebSocket channel for bidirectional note sync.

  Topic: "sync:{user_id}:{vault_id}"
  Auth:  socket.assigns.current_user must match user_id; vault must belong to that user.

  Client → Server events: none — every write rides the crdt: channel
  (crdt_msg / crdt_create / crdt_delete / crdt_catchup_since); the legacy
  inbound ops (push_note, delete_note, rename_note, pull_changes) had no
  remaining caller in any shipped client and were removed.
  Server → Client broadcasts: note_changed
  """

  use Phoenix.Channel

  alias Engram.Crypto.HMAC
  alias Engram.Logger.Metadata
  alias Engram.Vaults
  alias EngramWeb.Presence

  require Logger

  # ---------------------------------------------------------------------------
  # Join
  # ---------------------------------------------------------------------------

  @impl true
  def join("sync:" <> ids, params, socket) do
    do_join(ids, params, socket, socket.assigns.current_user)
  end

  defp do_join(ids, params, socket, user) do
    case String.split(ids, ":") do
      [user_id_str, vault_id_str] ->
        if to_string(user.id) == user_id_str do
          resolve_vault_and_join(vault_id_str, params, socket, user)
        else
          {:error, %{reason: "unauthorized"}}
        end

      _ ->
        {:error, %{reason: "invalid_topic"}}
    end
  end

  defp resolve_vault_and_join(vault_id_str, params, socket, user) do
    case Ecto.UUID.cast(vault_id_str) do
      {:ok, vault_id} ->
        case Vaults.get_vault(user, vault_id) do
          {:ok, vault} -> attach_vault_to_socket(vault, params, socket)
          {:error, _} -> {:error, %{reason: "vault_not_found"}}
        end

      :error ->
        {:error, %{reason: "invalid_vault_id"}}
    end
  end

  defp attach_vault_to_socket(vault, params, socket) do
    case check_api_key_access(socket, vault) do
      :ok ->
        socket = assign(socket, :vault, vault)
        send(self(), {:after_join, params})
        {:ok, %{reconnect_jitter_max_ms: reconnect_jitter_max_ms()}, socket}

      :forbidden ->
        {:error, %{reason: "api_key_vault_forbidden"}}
    end
  end

  defp reconnect_jitter_max_ms do
    Application.get_env(:engram, :reconnect_jitter_max_ms, 5_000)
  end

  @impl true
  def handle_info({:after_join, params}, socket) do
    device_id = socket.assigns[:device_id] || Map.get(params, "device_id", "unknown")
    conn_id = socket.assigns[:conn_id]
    vault_id = socket.assigns.vault.id

    log_meta =
      Metadata.with_category(:info, :websocket,
        conn_id: conn_id,
        device_id: device_id,
        topic: socket.topic,
        user_id: HMAC.hash_user_id(to_string(socket.assigns.current_user.id))
      )

    Logger.info("sync join", log_meta)

    warn_if_duplicate_device(socket, device_id, conn_id)

    {:ok, _} =
      Presence.track(socket, device_id, %{
        joined_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        vault_id: vault_id,
        conn_id: conn_id
      })

    push(socket, "presence_state", Presence.list(socket))
    {:noreply, socket}
  end

  # A zombie channel = two live sockets for one device. If this device already
  # has a tracked presence on this topic when a second socket joins, that is the
  # direct server-side fingerprint. Note: a fast reconnect can briefly overlap
  # (old presence not yet reaped), so this can occasionally fire on a healthy
  # churn; it is warn-level and rare, and the conn_ids disambiguate.
  defp warn_if_duplicate_device(socket, device_id, conn_id) do
    case Map.get(Presence.list(socket), device_id) do
      %{metas: metas} when metas != [] ->
        existing = metas |> Enum.map(& &1[:conn_id]) |> Enum.reject(&is_nil/1) |> Enum.join(",")

        Logger.warning(
          "duplicate live channel",
          Metadata.with_category(:warning, :websocket,
            conn_id: conn_id,
            device_id: device_id,
            topic: socket.topic,
            reason: "existing_conn_ids=#{existing}"
          )
        )

      _ ->
        :ok
    end
  end

  @impl true
  def terminate(reason, socket) do
    Logger.info(
      "sync leave",
      Metadata.with_category(:info, :websocket,
        conn_id: socket.assigns[:conn_id],
        device_id: socket.assigns[:device_id],
        topic: socket.topic,
        reason: inspect(reason)
      )
    )

    :ok
  end

  # ---------------------------------------------------------------------------
  # Inbound catch-all
  # ---------------------------------------------------------------------------

  # No inbound ops remain on this channel (all writes ride crdt:). Phoenix has
  # NO default handle_in — an unmatched frame raises and crashes the channel
  # process (noise + rejoin loop from any stray/legacy/malicious frame). Keep
  # the same reply-don't-crash posture as crdt_channel's catch-all and the
  # retired pull_changes "gone" stub (#862).
  @impl true
  def handle_in(_event, _params, socket),
    do: {:reply, {:error, %{"reason" => "gone", "use" => "crdt channel"}}, socket}

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp check_api_key_access(socket, vault) do
    Vaults.check_api_key_access(socket.assigns[:current_api_key], vault)
  end
end
