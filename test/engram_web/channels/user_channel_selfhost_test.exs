defmodule EngramWeb.UserChannelSelfhostTest do
  # async: false because it swaps the global storage adapter.
  use EngramWeb.ChannelCase, async: false

  test "a backend without multipart does not advertise chunked uploads" do
    Application.put_env(:engram, :storage, Engram.Storage.Database)
    on_exit(fn -> Application.put_env(:engram, :storage, Engram.Storage.InMemory) end)

    user = insert(:user)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "selfhost-features")
    {:ok, socket} = connect(EngramWeb.UserSocket, %{"token" => api_key})

    {:ok, reply, _socket} = subscribe_and_join(socket, "user:#{user.id}", %{})

    assert reply.features.chunked_attachment_upload == false
    refute Map.has_key?(reply.features, :attachment_part_size)
  end
end
