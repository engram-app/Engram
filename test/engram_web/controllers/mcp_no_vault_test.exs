defmodule EngramWeb.McpNoVaultTest do
  # User feedback 2026-10-24: a first MCP call on an account with no vault
  # answered "No vault found" and nothing about how to get one.
  use EngramWeb.ConnCase, async: false

  setup %{conn: conn} do
    prev = Application.get_env(:engram, :frontend_base_url)
    Application.put_env(:engram, :frontend_base_url, "https://app.example.test/")
    on_exit(fn -> Application.put_env(:engram, :frontend_base_url, prev) end)

    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    lift_api_rps_cap!(user)
    %{conn: put_req_header(conn, "authorization", "Bearer #{api_key}")}
  end

  test "the no-vault error says where to create one, from config", %{conn: conn} do
    conn = call_tool(conn, "list_folders")
    assert json_response(conn, 200)["result"]["isError"] == true
    text = tool_text(conn)

    assert text =~ "No vault found"
    assert text =~ "https://app.example.test/onboard"
    assert text =~ "Obsidian"
  end
end
