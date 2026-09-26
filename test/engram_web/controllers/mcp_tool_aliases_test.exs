defmodule EngramWeb.McpToolAliasesTest do
  use EngramWeb.ConnCase, async: true

  # Task 3.2 — deprecated alias calls (Task 3.1) get a text hint naming their
  # replacement while structuredContent stays byte-identical to the
  # pre-deprecation tool, and telemetry still tags the call with the alias name.

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Test Vault", Ecto.UUID.generate())
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    grant_api_write!(user)
    authed = put_req_header(conn, "authorization", "Bearer #{api_key}")

    %{conn: authed, user: user, vault: vault}
  end

  defp jsonrpc(conn, method, params) do
    post(conn, "/api/mcp", %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => params
    })
  end

  test "get_note alias: same structuredContent, deprecation line, own telemetry tag", ctx do
    %{conn: conn, user: user, vault: vault} = ctx
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)

    {:ok, _} =
      Engram.Notes.upsert_note(user, vault, %{
        "path" => "A.md",
        "content" => "# A\n\nhi",
        "mtime" => 1.0
      })

    ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :mcp, :tool, :stop]])

    resp =
      conn
      |> jsonrpc("tools/call", %{"name" => "get_note", "arguments" => %{"source_path" => "A.md"}})
      |> json_response(200)

    result = resp["result"]
    assert result["structuredContent"]["path"] == "A.md"
    assert result["structuredContent"]["content"] =~ "hi"
    [%{"text" => text}] = result["content"]
    assert text =~ "get_note is deprecated; use get_notes"

    assert_receive {[:engram, :mcp, :tool, :stop], ^ref, _, %{tool: :get_note, status: :ok}}
  end

  test "set_vault alias still validates a vault by name", ctx do
    %{conn: conn, vault: vault} = ctx

    resp =
      conn
      |> jsonrpc("tools/call", %{
        "name" => "set_vault",
        "arguments" => %{"vault_id" => vault.name}
      })
      |> json_response(200)

    assert resp["result"]["structuredContent"]["vault"]["id"] == to_string(vault.id)
  end
end
