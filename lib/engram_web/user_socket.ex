defmodule EngramWeb.UserSocket do
  use Phoenix.Socket

  channel "sync:*", EngramWeb.SyncChannel
  channel "user:*", EngramWeb.UserChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case Engram.Auth.TokenResolver.resolve(token) do
      {:ok, user} ->
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
