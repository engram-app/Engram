defmodule Engram.Auth.SessionInvalidatorTest do
  use Engram.DataCase, async: false

  alias Engram.Auth.SessionInvalidator

  test "disconnect_user/1 broadcasts disconnect on user_socket:{id}" do
    user_id = Ecto.UUID.generate()
    topic = "user_socket:#{user_id}"
    EngramWeb.Endpoint.subscribe(topic)

    assert :ok = SessionInvalidator.disconnect_user(user_id)

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^topic,
      event: "disconnect",
      payload: %{}
    }
  end

  test "disconnect_user/1 accepts a uuid string user id" do
    user_id = Ecto.UUID.generate()
    EngramWeb.Endpoint.subscribe("user_socket:#{user_id}")

    assert :ok = SessionInvalidator.disconnect_user(user_id)

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "user_socket:" <> ^user_id,
      event: "disconnect"
    }
  end

  test "disconnect_user/1 returns :ok even when no subscribers" do
    assert :ok = SessionInvalidator.disconnect_user(Ecto.UUID.generate())
  end
end
