defmodule EngramWeb.UserSocket do
  use Phoenix.Socket

  channel "sync:*", EngramWeb.SyncChannel
  channel "user:*", EngramWeb.UserChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case Engram.Auth.TokenResolver.resolve(token) do
      {:ok, user} ->
        {:ok, assign(socket, %{current_user: user, current_api_key: nil})}

      {:ok, user, :internal_jwt} ->
        # Device-flow / OAuth / MCP access tokens. Mirror the Auth plug's
        # branch — current_api_key stays nil so downstream code that
        # branches on its presence (e.g. SyncChannel api-key vault
        # restriction) doesn't misclassify this as a PAT auth and try to
        # treat the atom `:internal_jwt` as a struct.
        {:ok, assign(socket, %{current_user: user, current_api_key: nil})}

      {:ok, user, api_key} ->
        {:ok, assign(socket, %{current_user: user, current_api_key: api_key})}

      {:error, _reason} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.current_user.id}"
end
