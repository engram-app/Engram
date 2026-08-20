defmodule EngramWeb.ChannelCase do
  @moduledoc """
  Test case for Phoenix Channels.
  Handles Ecto Sandbox sharing with the spawned channel process.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import Engram.ApiEntitlementHelpers
      import Engram.Factory

      @endpoint EngramWeb.Endpoint

      @doc "Build a socket assigned to the given user (JWT-like, no API key restriction)."
      def user_socket(user) do
        socket(EngramWeb.UserSocket, "user_#{user.id}", %{
          current_user: user,
          current_api_key: nil
        })
      end

      @doc "Build a socket assigned to the given user with an API key."
      def user_socket(user, api_key) do
        socket(EngramWeb.UserSocket, "user_#{user.id}", %{
          current_user: user,
          current_api_key: api_key
        })
      end

      @doc "Join the sync channel and allow the channel pid to use the sandbox."
      def join_sync(socket, user, vault) do
        result =
          subscribe_and_join(
            socket,
            EngramWeb.SyncChannel,
            "sync:#{user.id}:#{vault.id}"
          )

        case result do
          {:ok, reply, joined_socket} ->
            Ecto.Adapters.SQL.Sandbox.allow(
              Engram.Repo,
              self(),
              joined_socket.channel_pid
            )

            {:ok, reply, joined_socket}

          error ->
            error
        end
      end
    end
  end

  setup tags do
    Engram.DataCase.setup_sandbox(tags)
    :ok
  end
end
