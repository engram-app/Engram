defmodule Engram.Auth.SessionInvalidatorTest do
  use Engram.DataCase, async: false

  alias Engram.Auth.SessionInvalidator

  test "disconnect_user/1 broadcasts disconnect on user_socket:{id}" do
    user_id = 12_345
    topic = "user_socket:#{user_id}"
    EngramWeb.Endpoint.subscribe(topic)

    assert :ok = SessionInvalidator.disconnect_user(user_id)

    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^topic,
      event: "disconnect",
      payload: %{}
    }
  end

  test "disconnect_user/1 accepts integer or string user id" do
    EngramWeb.Endpoint.subscribe("user_socket:42")

    assert :ok = SessionInvalidator.disconnect_user("42")

    assert_receive %Phoenix.Socket.Broadcast{topic: "user_socket:42", event: "disconnect"}
  end

  test "disconnect_user/1 returns :ok even when no subscribers" do
    assert :ok = SessionInvalidator.disconnect_user(99_999_999)
  end
end
