defmodule EngramWeb.WriteActorTest do
  use ExUnit.Case, async: true

  alias EngramWeb.WriteActor

  test "an API key is its own actor" do
    conn = %Plug.Conn{assigns: %{current_api_key: %{id: "key-1"}}}
    assert WriteActor.for_conn(conn) == "api:key-1"
  end

  test "anything else is the user's own client" do
    assert WriteActor.for_conn(%Plug.Conn{assigns: %{}}) == "sync"
  end
end
