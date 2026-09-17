defmodule EngramWeb.McpPingTest do
  @moduledoc """
  `ping` is part of the base protocol in every revision we support: the
  receiver MUST respond promptly with an empty result. We answered
  `-32601 Method not found` instead, which our own suite could not see —
  no test asked, and no first-party client we drive sends it.

  The third-party mcpjam conformance run against staging did
  (`scripts/mcp-conformance.sh`), and failed the `ping` check on both
  `2025-03-26` and `2025-06-18`.
  """
  use EngramWeb.ConnCase, async: true

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, _vault, _} = Engram.Vaults.register_vault(user, "Test Vault", Ecto.UUID.generate())
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    grant_api_write!(user)

    %{conn: put_req_header(conn, "authorization", "Bearer #{api_key}")}
  end

  defp ping(conn, params) do
    body = %{"jsonrpc" => "2.0", "id" => 7, "method" => "ping"}
    body = if params, do: Map.put(body, "params", params), else: body

    conn |> post("/api/mcp", body) |> json_response(200)
  end

  test "responds with an empty result", %{conn: conn} do
    assert %{"jsonrpc" => "2.0", "id" => 7, "result" => result} = ping(conn, nil)
    assert result == %{}
  end

  test "ignores params the client attaches", %{conn: conn} do
    assert %{"result" => %{}} = ping(conn, %{"_meta" => %{"progressToken" => "abc"}})
  end

  test "an unrelated unknown method is still Method not found", %{conn: conn} do
    assert %{"error" => %{"code" => -32_601}} =
             conn
             |> post("/api/mcp", %{"jsonrpc" => "2.0", "id" => 8, "method" => "pong"})
             |> json_response(200)
  end
end
