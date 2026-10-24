defmodule EngramWeb.McpToolCallRateLimitTest do
  @moduledoc """
  Per-user `tools/call` budget for MCP traffic without an API key
  (`mcp_tool_calls_per_min`, 2026-10-24). Before it, an OAuth MCP client was
  bounded only by the 600/min pre-auth bucket; API keys already had
  `api_rps_cap`. Driven through the real `POST /api/mcp` route, because a
  limit in a path-shaped plug never fires for MCP
  (docs/context/mcp-bypasses-path-shaped-plugs.md).

  async: false: one test flips the global `:limits_enforced` env.
  """
  use EngramWeb.ConnCase, async: false

  import Engram.OAuthHelpers, only: [code_from_redirect: 1, pkce_pair: 0]

  alias Engram.OAuth

  @redirect "https://client.example/cb"

  setup do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    # OAuth access tokens resolve their user by external id.
    user = ensure_external_id(user)
    {:ok, _vault, _} = Engram.Vaults.register_vault(user, "V", Ecto.UUID.generate())
    %{user: user}
  end

  defp oauth_token(user) do
    {:ok, client} =
      OAuth.register_client(%{"redirect_uris" => [@redirect], "client_name" => "Client"})

    {verifier, challenge} = pkce_pair()

    {:ok, validated} =
      OAuth.validate_authorization_request(%{
        "client_id" => client.client_id,
        "redirect_uri" => @redirect,
        "response_type" => "code",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "scope" => "mcp"
      })

    {:ok, url} = OAuth.mint_authorization_code(user, validated, :all, nil)

    {:ok, tokens} =
      OAuth.exchange_authorization_code(%{
        "code" => code_from_redirect(url),
        "redirect_uri" => @redirect,
        "client_id" => client.client_id,
        "code_verifier" => verifier
      })

    tokens.access_token
  end

  defp set_cap(user, n) do
    insert(:user_limit_override, user: user, key: "mcp_tool_calls_per_min", value: %{"v" => n})
    Engram.Billing.OverrideCache.evict(user.id)
  end

  defp rpc(token, method, params) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> post("/api/mcp", %{"jsonrpc" => "2.0", "id" => 7, "method" => method, "params" => params})
  end

  defp tool_call(token),
    do: rpc(token, "tools/call", %{"name" => "list_vaults", "arguments" => %{}})

  # The limiter's windows are epoch-aligned; a burst must not straddle an edge
  # (`EngramWeb.RateLimiter.fresh_window_wait_ms/1`), or the denied call lands
  # in a new window. Per-user keys, so no global bucket wipe is needed.
  defp at_fresh_window do
    case EngramWeb.RateLimiter.fresh_window_wait_ms(System.system_time(:millisecond)) do
      0 -> :ok
      wait -> Process.sleep(wait)
    end
  end

  test "an OAuth client past its tools/call budget gets 429, Retry-After and a JSON-RPC error",
       %{user: user} do
    set_cap(user, 2)
    token = oauth_token(user)
    at_fresh_window()

    assert json_response(tool_call(token), 200)["result"]
    assert json_response(tool_call(token), 200)["result"]

    conn = tool_call(token)
    body = json_response(conn, 429)

    assert [retry_after] = get_resp_header(conn, "retry-after")
    assert String.to_integer(retry_after) in 1..60
    assert body["jsonrpc"] == "2.0"
    assert body["id"] == 7
    assert body["error"]["message"] =~ "2 tool calls per minute"
    assert body["error"]["data"]["error"] == "mcp_tool_rate_exceeded"
    assert body["error"]["data"]["limit"] == 2
  end

  test "only tools/call counts: handshake and list methods spend nothing", %{user: user} do
    set_cap(user, 1)
    token = oauth_token(user)
    at_fresh_window()

    init = %{"protocolVersion" => "2025-03-26", "clientInfo" => %{"name" => "t"}}
    for _ <- 1..3, do: assert(json_response(rpc(token, "initialize", init), 200)["result"])
    for _ <- 1..3, do: assert(json_response(rpc(token, "tools/list", %{}), 200)["result"])

    assert json_response(tool_call(token), 200)["result"]
    assert json_response(tool_call(token), 429)
  end

  test "API-key traffic is under api_rps_cap, not this budget", %{user: user} do
    set_cap(user, 1)
    lift_api_rps_cap!(user)
    {:ok, key, _} = Engram.Accounts.create_api_key(user, "k")
    at_fresh_window()

    for _ <- 1..3, do: assert(json_response(tool_call(key), 200)["result"])
  end

  test "no budget when limits are not enforced (self-host)", %{user: user} do
    set_cap(user, 1)
    token = oauth_token(user)
    prior = Application.get_env(:engram, :limits_enforced)
    Application.put_env(:engram, :limits_enforced, false)

    on_exit(fn ->
      if is_nil(prior),
        do: Application.delete_env(:engram, :limits_enforced),
        else: Application.put_env(:engram, :limits_enforced, prior)
    end)

    at_fresh_window()
    for _ <- 1..3, do: assert(json_response(tool_call(token), 200)["result"])
  end
end
