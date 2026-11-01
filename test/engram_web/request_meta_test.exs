defmodule EngramWeb.RequestMetaTest do
  use ExUnit.Case, async: true

  alias EngramWeb.RequestMeta

  defp conn_with_ua(ua),
    do: Plug.Test.conn(:get, "/") |> Plug.Conn.put_req_header("user-agent", ua)

  describe "log_user_agent/1" do
    test "keeps a real user agent whole" do
      assert RequestMeta.log_user_agent(conn_with_ua("Claude-User/1.0")) == "Claude-User/1.0"
    end

    # Attacker-controlled and up to Bandit's 10 KB header cap: bounded before
    # it reaches a log line.
    test "bounds an oversized one to 200 characters" do
      assert RequestMeta.log_user_agent(conn_with_ua(String.duplicate("a", 5_000))) ==
               String.duplicate("a", 200)
    end

    # String.slice/3 counts graphemes, and one grapheme can carry thousands of
    # combining marks: 200 graphemes is not a byte bound.
    test "bounds bytes, not graphemes, and stays valid UTF-8" do
      ua = "a" <> String.duplicate("\u0301", 5_000)
      logged = RequestMeta.log_user_agent(conn_with_ua(ua))

      assert byte_size(logged) <= 200
      assert String.valid?(logged)
    end

    test "is nil without the header" do
      assert RequestMeta.log_user_agent(Plug.Test.conn(:get, "/")) == nil
    end
  end

  describe "surface/1" do
    test "an API key is api" do
      assert RequestMeta.surface(%{current_api_key: %{id: "k"}}) == "api"
    end

    test "a device token is the Obsidian plugin" do
      assert RequestMeta.surface(%{current_auth_method: :internal_jwt}) == "obsidian_sync"
    end

    test "a Clerk session is the web app" do
      assert RequestMeta.surface(%{}) == "web"
    end

    # An MCP-audience OAuth token is an AI client, not the plugin it used to
    # be filed under.
    test "an MCP-audience OAuth token is mcp" do
      assert RequestMeta.surface(mcp_assigns(%{"client_id" => "c-1"})) == "mcp"
    end
  end

  describe "log_surface/1" do
    test "names the MCP client behind an MCP token" do
      assert RequestMeta.log_surface(mcp_assigns(%{"client_id" => "c-1"})) == "mcp:c-1"
    end

    # A token minted before its grant named a client (no `gid`).
    test "an MCP token with no client is mcp:unknown" do
      assert RequestMeta.log_surface(mcp_assigns(%{})) == "mcp:unknown"
    end

    test "is the analytics surface for everything else" do
      assert RequestMeta.log_surface(%{current_api_key: %{id: "k"}}) == "api"
      assert RequestMeta.log_surface(%{}) == "web"
    end
  end

  describe "log_route/1" do
    test "is the matched controller#action once a controller ran" do
      conn =
        Plug.Test.conn(:get, "/x")
        |> Plug.Conn.put_private(:phoenix_controller, EngramWeb.NotesController)
        |> Plug.Conn.put_private(:phoenix_action, :show)

      assert RequestMeta.log_route(conn) == "EngramWeb.NotesController#show"
    end

    # A pipeline plug that halts (RequireOnboarding's 403) runs before the
    # controller, so `phoenix_controller` is never set.
    test "resolves from the route table when the router halted before a controller" do
      conn =
        Plug.Test.conn(:get, "/api/vault/tree")
        |> Plug.Conn.put_private(:phoenix_router, EngramWeb.Router)

      assert RequestMeta.log_route(conn) == "EngramWeb.VaultTreeController#show"
    end

    test "is nil when the router never ran (static asset, endpoint plug)" do
      assert RequestMeta.log_route(Plug.Test.conn(:get, "/api/vault/tree")) == nil
    end
  end

  defp mcp_assigns(extra) do
    %{
      current_auth_method: :internal_jwt,
      grant_claims: {:ok, Map.merge(%{"aud" => Engram.Token.mcp_audience()}, extra)}
    }
  end
end
