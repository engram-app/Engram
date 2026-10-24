defmodule EngramWeb.McpErrorCodesTest do
  # User feedback 2026-10-24 (ChatGPT): a failed create_note read like the
  # client's own safety refusal. Every Engram tool error now carries a stable
  # code, in the text the model reads and in `_meta` for programs.
  use EngramWeb.ConnCase, async: true

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Test Vault", Ecto.UUID.generate())
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    lift_api_rps_cap!(user)
    %{conn: put_req_header(conn, "authorization", "Bearer #{api_key}"), user: user, vault: vault}
  end

  defp assert_code(conn, code) do
    result = json_response(conn, 200)["result"]
    assert result["isError"] == true
    assert result["_meta"]["engram.page/error_code"] == code
    assert tool_text(conn) =~ "(Engram error code: #{code})"
    assert tool_text(conn) =~ "Error: "
  end

  test "create_note on a taken path is path_conflict", %{conn: conn, user: u, vault: v} do
    {:ok, _} =
      Engram.Notes.upsert_note(u, v, %{"path" => "P/Taken.md", "content" => "x", "mtime" => 1.0},
        actor: "api"
      )

    args = %{"title" => "Taken", "content" => "y", "suggested_folder" => "P"}
    conn |> call_tool("create_note", args) |> assert_code("path_conflict")
  end

  test "an unknown vault_id is vault_not_found", %{conn: conn} do
    conn
    |> call_tool("create_note", %{"title" => "T", "content" => "c", "vault_id" => "Nope"})
    |> assert_code("vault_not_found")
  end

  test "an oversized write_note is note_too_large", %{conn: conn} do
    big = String.duplicate("a", Engram.Notes.max_note_bytes() + 1)

    conn
    |> call_tool("write_note", %{"path" => "Big.md", "content" => big})
    |> assert_code("note_too_large")
  end

  test "a malformed argument is invalid_arguments", %{conn: conn} do
    conn
    |> call_tool("write_note", %{"path" => 5, "content" => "c"})
    |> assert_code("invalid_arguments")
  end

  test "an error with no specific cause still carries tool_error", %{conn: conn} do
    conn |> call_tool("get_notes", %{"paths" => []}) |> assert_code("tool_error")
  end
end
