defmodule EngramWeb.ApiKeyAllTiersTest do
  @moduledoc """
  A personal API key works on every route on every tier (#1974): REST, MCP
  and the sync sockets alike.

  Cost is metered where it is incurred (`ai_searches_per_day` at the search
  cost site, `notes_cap` on writes), not by which
  credential called. Abuse is bounded by `PreAuthRateLimit` and `api_rps_cap`
  (30/s on every tier), which stays as a per-user kill switch.
  """
  # async: false — the rate-limiter bucket store is global.
  use EngramWeb.ConnCase, async: false

  alias Engram.OAuth

  setup %{conn: conn} do
    EngramWeb.RateLimiter.reset_buckets!()
    # A Free user with no overrides: the defaults are what is under test.
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "V", Ecto.UUID.generate())
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "k")

    %{conn: put_req_header(conn, "authorization", "Bearer #{api_key}"), user: user, vault: vault}
  end

  defp tools_list(conn),
    do: post(conn, "/api/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

  test "a Free user's key reads the REST API", %{conn: conn, vault: vault} do
    conn = conn |> put_req_header("x-vault-id", vault.id) |> get("/api/tags")
    assert conn.status == 200
  end

  test "a Free user's key writes through the REST API", %{conn: conn, vault: vault} do
    conn =
      conn
      |> put_req_header("x-vault-id", vault.id)
      |> post("/api/notes", %{"path" => "a.md", "content" => "hello"})

    assert conn.status in [200, 201]
  end

  test "a Free user's key uses MCP", %{conn: conn} do
    assert %{"result" => %{"tools" => [_ | _]}} = conn |> tools_list() |> json_response(200)
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

  # Removing the key needs no migration: a leftover row is never read.
  test "a leftover api_write_enabled=false override is inert", %{
    conn: conn,
    user: user,
    vault: vault
  } do
    insert(:user_limit_override, user: user, key: "api_write_enabled", value: %{"v" => false})
    Engram.Billing.OverrideCache.evict(user.id)

    conn =
      conn
      |> put_req_header("x-vault-id", vault.id)
      |> post("/api/notes", %{"path" => "b.md", "content" => "hi"})

    assert conn.status in [200, 201]
  end

  test "api_rps_cap = 0 still refuses a key (per-user kill switch)", %{conn: conn, user: user} do
    insert(:user_limit_override, user: user, key: "api_rps_cap", value: %{"v" => 0})
    Engram.Billing.OverrideCache.evict(user.id)

    assert %{"error" => "api_rps_exceeded"} = conn |> get("/api/notes") |> json_response(429)
  end
end
