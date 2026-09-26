defmodule EngramWeb.McpToolAliasesTest do
  use EngramWeb.ConnCase, async: true

  alias Engram.MCP.Tools

  # Task 3.2 — deprecated alias calls (Task 3.1) get a text hint naming their
  # replacement while structuredContent stays byte-identical to the
  # pre-deprecation tool, and telemetry still tags the call with the alias name.
  #
  # For each of the 5 aliases, the equality checks below prove "same
  # structuredContent as before" by comparing the FULL map returned over
  # HTTP against the FULL map the alias's own handler returns when called
  # directly — not by spot-checking a couple of fields, which could stay
  # green while some other key silently drifted.

  # `Tools.get/1` -> `tool.handler` gives the exact function `wire_list`
  # dispatches for this alias name; calling it directly bypasses HTTP/JSON
  # round-tripping so the comparison is apples-to-apples with the response's
  # `structuredContent` (which already went through Jason encode/decode).
  defp direct_structured(name, user, vault, args) do
    {:ok, tool} = Tools.get(name)
    {:ok, _text, structured} = tool.handler.(user, vault, args)
    structured |> Jason.encode!() |> Jason.decode!()
  end

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

    args = %{"source_path" => "A.md"}
    assert result["structuredContent"] == direct_structured("get_note", user, vault, args)
  end

  test "set_vault alias still validates a vault by name", ctx do
    %{conn: conn, user: user, vault: vault} = ctx

    args = %{"vault_id" => vault.name}

    resp =
      conn
      |> jsonrpc("tools/call", %{"name" => "set_vault", "arguments" => args})
      |> json_response(200)

    assert resp["result"]["structuredContent"]["vault"]["id"] == to_string(vault.id)

    # set_vault's handler is dispatched with the credential's ACCESSIBLE
    # vault list, not a single vault (it validates a name/id against that
    # set) — see `dispatch_tool/4`'s `@vault_exempt` clause.
    accessible = Engram.Vaults.list_vaults(user)

    assert resp["result"]["structuredContent"] ==
             direct_structured("set_vault", user, accessible, args)
  end

  test "list_folders alias: same structuredContent as calling its handler directly", ctx do
    %{conn: conn, user: user, vault: vault} = ctx
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)

    {:ok, _} =
      Engram.Notes.upsert_note(user, vault, %{
        "path" => "Health/A.md",
        "content" => "# A\n\nhi",
        "mtime" => 1.0
      })

    resp =
      conn
      |> jsonrpc("tools/call", %{"name" => "list_folders", "arguments" => %{}})
      |> json_response(200)

    assert resp["result"]["structuredContent"] ==
             direct_structured("list_folders", user, vault, %{})
  end

  test "patch_note alias: same structuredContent as calling its handler directly", ctx do
    %{conn: conn, user: user, vault: vault} = ctx
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    original = "# P\n\nhello world"

    {:ok, _} =
      Engram.Notes.upsert_note(user, vault, %{
        "path" => "P.md",
        "content" => original,
        "mtime" => 1.0
      })

    args = %{"path" => "P.md", "find" => "hello", "replace" => "hi"}

    # Calling the handler directly mutates the note (find/replace), so it
    # runs FIRST against the seeded original, then the note is reset before
    # the HTTP call repeats the identical mutation — otherwise the second
    # call would see already-replaced text and fail to find it.
    direct = direct_structured("patch_note", user, vault, args)

    {:ok, _} =
      Engram.Notes.upsert_note(user, vault, %{
        "path" => "P.md",
        "content" => original,
        "mtime" => 2.0
      })

    resp =
      conn
      |> jsonrpc("tools/call", %{"name" => "patch_note", "arguments" => args})
      |> json_response(200)

    assert resp["result"]["structuredContent"] == direct
  end

  test "update_section alias: same structuredContent as calling its handler directly", ctx do
    %{conn: conn, user: user, vault: vault} = ctx
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    original = "# P\n\n## Notes\n\nold text\n\n## Next\n\nkeep"

    {:ok, _} =
      Engram.Notes.upsert_note(user, vault, %{
        "path" => "P.md",
        "content" => original,
        "mtime" => 1.0
      })

    args = %{"path" => "P.md", "heading" => "Notes", "content" => "new text"}

    # Same reset-between-calls reasoning as patch_note above: update_section
    # mutates the note, so the direct handler call runs first, then the note
    # is reset before the HTTP call repeats the identical mutation.
    direct = direct_structured("update_section", user, vault, args)

    {:ok, _} =
      Engram.Notes.upsert_note(user, vault, %{
        "path" => "P.md",
        "content" => original,
        "mtime" => 2.0
      })

    resp =
      conn
      |> jsonrpc("tools/call", %{"name" => "update_section", "arguments" => args})
      |> json_response(200)

    assert resp["result"]["structuredContent"] == direct
  end
end
