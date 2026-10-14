defmodule EngramWeb.McpApiKeyTierTest do
  @moduledoc """
  MCP over a personal API key works on every tier (#1974).

  The REST API stays Pro: `api_rps_cap` / `api_write_enabled` still gate it.
  But `/api/mcp` is the same product a Free user already gets over OAuth, and
  an API key is the fallback for clients whose OAuth flow is broken (Muse,
  key-oriented clients). MCP connections are uncapped on every tier, OAuth
  and keys alike: the only MCP limit is the `ai_searches_per_day` meter,
  charged in `Engram.Search.search/4` for every transport.
  """
  # async: false — the rate-limiter bucket store is global.
  use EngramWeb.ConnCase, async: false

  alias Engram.OAuth

  setup %{conn: conn} do
    EngramWeb.RateLimiter.reset_buckets!()
    # A Free user: api_rps_cap 0, api_write_enabled false.
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, _vault, _} = Engram.Vaults.register_vault(user, "V", Ecto.UUID.generate())
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "k")

    %{conn: put_req_header(conn, "authorization", "Bearer #{api_key}"), user: user}
  end

  defp tools_list(conn),
    do: post(conn, "/api/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

  test "a Free user's API key can use MCP", %{conn: conn} do
    conn = tools_list(conn)
    assert conn.status == 200
    assert %{"result" => %{"tools" => [_ | _]}} = json_response(conn, 200)
  end

  test "the same key is still refused on the REST API", %{conn: conn} do
    conn = get(conn, "/api/notes")
    assert conn.status == 429
    assert %{"error" => "api_rps_exceeded"} = json_response(conn, 429)
  end

  test "a key works alongside any number of OAuth MCP grants", %{conn: conn, user: user} do
    for name <- ["Claude", "ChatGPT"] do
      {:ok, client} =
        OAuth.register_client(%{
          "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"],
          "client_name" => name
        })

      insert(:oauth_refresh_token, user_id: user.id, client_id: client.client_id)
    end

    assert conn |> tools_list() |> json_response(200)
  end
end
