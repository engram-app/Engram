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

  describe "surface/1" do
    test "an API key is api" do
      assert WriteActor.surface(%Plug.Conn{assigns: %{current_api_key: %{id: "k"}}}) == "api"
    end

    test "a device / OAuth token is the Obsidian plugin" do
      assert WriteActor.surface(%Plug.Conn{assigns: %{current_auth_method: :internal_jwt}}) ==
               "obsidian_sync"
    end

    test "a Clerk session is the web app" do
      assert WriteActor.surface(%Plug.Conn{assigns: %{}}) == "web"
    end
  end
end
