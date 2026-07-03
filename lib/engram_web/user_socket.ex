defmodule EngramWeb.UserSocket do
  use Phoenix.Socket

  require Logger

  alias Engram.Crypto.HMAC
  alias Engram.Logger.Metadata

  channel "sync:*", EngramWeb.SyncChannel
  channel "crdt:*", EngramWeb.CrdtChannel
  channel "user:*", EngramWeb.UserChannel

  @impl true
  def connect(%{"token" => token} = params, socket, _connect_info) do
    case Engram.Auth.TokenResolver.resolve(token) do
      {:ok, user} ->
        {:ok, accept(socket, user, nil, params)}

      {:ok, user, :internal_jwt} ->
        # Device-flow / OAuth / MCP access tokens. Mirror the Auth plug's
        # branch — current_api_key stays nil so downstream code that
        # branches on its presence (e.g. SyncChannel api-key vault
        # restriction) doesn't misclassify this as a PAT auth and try to
        # treat the atom `:internal_jwt` as a struct.
        {:ok, accept(socket, user, nil, params)}

      {:ok, user, api_key} ->
        {:ok, accept(socket, user, api_key, params)}

      {:error, reason} ->
        # Previously silent — during a Clerk break every SPA reconnect storms
        # this path with no log and no metric. Mirror the HTTP plug.
        label = Engram.Auth.emit_rejected(reason, :socket)

        Logger.warning(
          "auth rejected",
          Metadata.with_category(:warning, :auth, reason: label)
        )

        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  # Stamps connection-correlation ids into assigns and logs the connect. The
  # ids are client-supplied (URL query params); conn_id is unique per physical
  # socket, device_id is stable per install. Both are echoed on every channel
  # lifecycle log so a plugin log line and a backend log line for the same
  # socket share a key.
  defp accept(socket, user, api_key, params) do
    conn_id = params["conn_id"]
    device_id = params["device_id"]
    vault_id = params["vault_id"]

    Logger.info(
      "ws connect",
      Metadata.with_category(:info, :websocket,
        conn_id: conn_id,
        device_id: device_id,
        user_id: HMAC.hash_user_id(to_string(user.id))
      )
    )

    assign(socket, %{
      current_user: user,
      current_api_key: api_key,
      conn_id: conn_id,
      device_id: device_id,
      vault_id_param: vault_id
    })
  end

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.current_user.id}"
end
