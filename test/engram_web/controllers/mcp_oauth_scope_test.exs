defmodule EngramWeb.McpOAuthScopeTest do
  use EngramWeb.ConnCase, async: true

  # Sanity test for Phase 5: tools called via /api/mcp under an OAuth-issued
  # JWT carrying a vault_id claim must route to that bound vault, and a
  # mismatched vault_id arg must be rejected. API-key auth (existing
  # behavior) and unscoped JWTs are also tested for backward compat.

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    vault_a = insert(:vault, user: user, slug: "vault-a", is_default: true)
    vault_b = insert(:vault, user: user, slug: "vault-b")

    {:ok, _} =
      Engram.Notes.upsert_note(user, vault_a, %{
        "path" => "a.md",
        "content" => "in vault A",
        "mtime" => 1.0
      })

    {:ok, _} =
      Engram.Notes.upsert_note(user, vault_b, %{
        "path" => "b.md",
        "content" => "in vault B",
        "mtime" => 1.0
      })

    %{conn: conn, user: user, vault_a: vault_a, vault_b: vault_b}
  end

  defp ensure_external_id(%{external_id: ext} = user) when is_binary(ext) and ext != "", do: user

  defp ensure_external_id(user) do
    {:ok, updated} =
      user
      |> Ecto.Changeset.change(external_id: "test-#{user.id}")
      |> Engram.Repo.update(skip_tenant_check: true)

    updated
  end

  defp oauth_authed(conn, user, vault_id) do
    user = ensure_external_id(user)
    token = Engram.Accounts.generate_jwt(user, %{"scope" => "mcp", "vault_id" => vault_id})
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp unscoped_jwt(conn, user) do
    user = ensure_external_id(user)
    token = Engram.Accounts.generate_jwt(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp call_tool(conn, name, args) do
    post(conn, "/api/mcp", %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => args}
    })
  end

  test "OAuth-bound vault_id with no args.vault_id routes to bound vault", %{
    conn: conn,
    user: user,
    vault_a: vault_a
  } do
    conn = conn |> oauth_authed(user, vault_a.id) |> call_tool("list_folders", %{})
    body = json_response(conn, 200)
    assert is_map(body["result"])
    refute Map.has_key?(body, "error")
  end

  test "OAuth-bound vault_id matching args.vault_id routes successfully", %{
    conn: conn,
    user: user,
    vault_a: vault_a
  } do
    conn =
      conn
      |> oauth_authed(user, vault_a.id)
      |> call_tool("list_folders", %{"vault_id" => vault_a.id})

    body = json_response(conn, 200)
    refute Map.has_key?(body, "error")
  end

  test "OAuth-bound vault_id with mismatched args.vault_id is rejected", %{
    conn: conn,
    user: user,
    vault_a: vault_a,
    vault_b: vault_b
  } do
    conn =
      conn
      |> oauth_authed(user, vault_a.id)
      |> call_tool("list_folders", %{"vault_id" => vault_b.id})

    body = json_response(conn, 200)

    # MCP wraps tool errors as a result with isError, OR as a JSON-RPC error.
    # Either way the response must surface the bound-vault enforcement.
    response_text = body["result"]["content"] |> Kernel.||([]) |> Enum.map_join(" ", & &1["text"])
    error_msg = body["error"]["message"] || ""
    assert response_text <> error_msg =~ "bound to vault"
  end

  test "unscoped internal JWT (no vault_id claim) keeps existing behavior", %{
    conn: conn,
    user: user
  } do
    conn = conn |> unscoped_jwt(user) |> call_tool("list_folders", %{})
    body = json_response(conn, 200)
    refute Map.has_key?(body, "error")
  end
end
