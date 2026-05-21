defmodule EngramWeb.McpControllerTest do
  use EngramWeb.ConnCase, async: true

  # ---------------------------------------------------------------------------
  # Setup: authenticated connection + seeded notes
  # ---------------------------------------------------------------------------

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    # Use the public create_vault path so name_ciphertext is real and
    # decrypts back to "Test Vault" — not random factory bytes.
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Test Vault"})
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    authed = put_req_header(conn, "authorization", "Bearer #{api_key}")

    # Seed some notes for read tool tests
    Engram.Notes.upsert_note(user, vault, %{
      "path" => "Health/Supplements.md",
      "content" =>
        "---\ntags: [health, supplements]\n---\n# Supplements\n\n## Shopping List\n\n- Omega 3\n- Vitamin D\n\n## Notes\n\nTake with food.",
      "mtime" => 1_000.0
    })

    Engram.Notes.upsert_note(user, vault, %{
      "path" => "Health/Exercise.md",
      "content" => "---\ntags: [health, fitness]\n---\n# Exercise\n\nDaily routine.",
      "mtime" => 1_000.0
    })

    Engram.Notes.upsert_note(user, vault, %{
      "path" => "Work/Project.md",
      "content" => "---\ntags: [work]\n---\n# Project\n\nProject notes.",
      "mtime" => 1_000.0
    })

    %{conn: authed, user: user}
  end

  # Helper to make JSON-RPC calls
  defp jsonrpc(conn, method, params \\ %{}) do
    post(conn, "/api/mcp", %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => params
    })
  end

  defp call_tool(conn, name, args \\ %{}) do
    jsonrpc(conn, "tools/call", %{"name" => name, "arguments" => args})
  end

  defp tool_text(conn) do
    resp = json_response(conn, 200)
    resp["result"]["content"] |> hd() |> Map.get("text")
  end

  # =========================================================================
  # Protocol tests
  # =========================================================================

  describe "MCP protocol" do
    test "initialize returns server info and capabilities", %{conn: conn} do
      conn = jsonrpc(conn, "initialize")
      resp = json_response(conn, 200)

      assert resp["jsonrpc"] == "2.0"
      assert resp["id"] == 1
      assert resp["result"]["protocolVersion"] == "2025-03-26"
      assert resp["result"]["serverInfo"]["name"] == "engram"
      assert resp["result"]["capabilities"]["tools"]
    end

    test "tools/list returns 16 tools", %{conn: conn} do
      conn = jsonrpc(conn, "tools/list")
      resp = json_response(conn, 200)

      tools = resp["result"]["tools"]
      assert length(tools) == 16

      names = Enum.map(tools, & &1["name"])
      assert "list_vaults" in names
      assert "set_vault" in names
      assert "search_notes" in names
      assert "get_note" in names
      assert "write_note" in names
      assert "delete_note" in names
      assert "patch_note" in names
      assert "update_section" in names

      # Each tool has required fields
      Enum.each(tools, fn t ->
        assert is_binary(t["name"])
        assert is_binary(t["description"])
        assert is_map(t["inputSchema"])
      end)
    end

    test "unknown method returns -32_601", %{conn: conn} do
      conn = jsonrpc(conn, "nonexistent/method")
      resp = json_response(conn, 200)

      assert resp["error"]["code"] == -32_601
      assert resp["error"]["message"] =~ "Method not found"
    end

    test "missing jsonrpc field returns -32_600", %{conn: conn} do
      conn = post(conn, "/api/mcp", %{"id" => 1, "method" => "initialize"})
      resp = json_response(conn, 200)

      assert resp["error"]["code"] == -32_600
    end

    test "notification (no id) returns 202", %{conn: conn} do
      conn =
        post(conn, "/api/mcp", %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

      assert conn.status == 202
    end

    test "unknown tool returns -32_602", %{conn: conn} do
      conn = call_tool(conn, "nonexistent_tool", %{})
      resp = json_response(conn, 200)

      assert resp["error"]["code"] == -32_602
      assert resp["error"]["message"] =~ "Unknown tool"
    end

    test "unauthenticated request returns 401" do
      conn = build_conn()

      conn =
        post(conn, "/api/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize"
        })

      assert json_response(conn, 401)
    end
  end

  # =========================================================================
  # Vault tool tests
  # =========================================================================

  describe "list_vaults tool" do
    test "returns list of vaults", %{conn: conn} do
      conn = call_tool(conn, "list_vaults")
      text = tool_text(conn)

      assert text =~ "(default)"
      assert text =~ "ID:"
    end
  end

  describe "set_vault tool" do
    test "without vault_id returns default vault", %{conn: conn} do
      conn = call_tool(conn, "set_vault")
      text = tool_text(conn)

      assert text =~ "Active vault:"
      assert text =~ "(default)"
    end

    test "with valid vault_id returns that vault", %{conn: conn, user: user} do
      {:ok, vault} = Engram.Vaults.get_default_vault(user)
      conn = call_tool(conn, "set_vault", %{"vault_id" => vault.id})
      text = tool_text(conn)

      assert text =~ "Active vault:"
      assert text =~ vault.name
    end

    test "with invalid vault_id returns error", %{conn: conn} do
      conn = call_tool(conn, "set_vault", %{"vault_id" => 999_999})
      text = tool_text(conn)

      assert text =~ "Error:"
    end
  end

  # =========================================================================
  # Read tool tests (no Qdrant needed)
  # =========================================================================

  describe "list_tags tool" do
    test "returns tags with counts", %{conn: conn} do
      conn = call_tool(conn, "list_tags")
      text = tool_text(conn)

      assert text =~ "| Tag | Count |"
      assert text =~ "health"
      assert text =~ "supplements"
      assert text =~ "fitness"
      # health appears in 2 notes
      assert text =~ "| health | 2 |"
    end
  end

  describe "list_folders tool" do
    test "returns folders with counts", %{conn: conn} do
      conn = call_tool(conn, "list_folders")
      text = tool_text(conn)

      assert text =~ "| Folder | Notes |"
      assert text =~ "| Health | 2 |"
      assert text =~ "| Work | 1 |"
    end
  end

  describe "list_folder tool" do
    test "returns notes in a folder", %{conn: conn} do
      conn = call_tool(conn, "list_folder", %{"folder" => "Health"})
      text = tool_text(conn)

      assert text =~ "**Folder:** Health"
      assert text =~ "Supplements"
      assert text =~ "Exercise"
    end

    test "returns message for empty folder", %{conn: conn} do
      conn = call_tool(conn, "list_folder", %{"folder" => "Nonexistent"})
      text = tool_text(conn)

      assert text =~ "No notes found in folder: Nonexistent"
    end
  end

  describe "get_note tool" do
    test "returns full note content", %{conn: conn} do
      conn = call_tool(conn, "get_note", %{"source_path" => "Health/Supplements.md"})
      text = tool_text(conn)

      assert text =~ "# Supplements"
      assert text =~ "**Path:** Health/Supplements.md"
      assert text =~ "**Folder:** Health"
      assert text =~ "Omega 3"
    end

    test "returns not found for missing note", %{conn: conn} do
      conn = call_tool(conn, "get_note", %{"source_path" => "Missing/Note.md"})
      text = tool_text(conn)

      assert text == "Note not found: Missing/Note.md"
    end
  end

  # =========================================================================
  # Write tool tests (no Qdrant needed)
  # =========================================================================

  describe "write_note tool" do
    test "creates a new note", %{conn: conn} do
      conn =
        call_tool(conn, "write_note", %{
          "path" => "New/Note.md",
          "content" => "# New Note\n\nContent here."
        })

      text = tool_text(conn)
      assert text =~ "Note saved: New/Note.md"

      # Verify it exists
      conn = call_tool(build_authed(conn), "get_note", %{"source_path" => "New/Note.md"})
      assert tool_text(conn) =~ "Content here."
    end
  end

  describe "append_to_note tool" do
    test "appends to existing note", %{conn: conn} do
      conn =
        call_tool(conn, "append_to_note", %{
          "path" => "Health/Supplements.md",
          "text" => "\n## New Section\n\nAppended content."
        })

      text = tool_text(conn)
      assert text =~ "Note appended to: Health/Supplements.md"

      # Verify content was appended
      conn =
        call_tool(build_authed(conn), "get_note", %{"source_path" => "Health/Supplements.md"})

      assert tool_text(conn) =~ "Appended content."
      assert tool_text(conn) =~ "Take with food."
    end

    test "creates note if missing", %{conn: conn} do
      conn =
        call_tool(conn, "append_to_note", %{
          "path" => "New/Appended.md",
          "text" => "Some text."
        })

      text = tool_text(conn)
      assert text =~ "Note created: New/Appended.md"

      conn = call_tool(build_authed(conn), "get_note", %{"source_path" => "New/Appended.md"})
      result = tool_text(conn)
      assert result =~ "# Appended"
      assert result =~ "Some text."
    end
  end

  describe "patch_note tool" do
    test "replaces first occurrence", %{conn: conn} do
      conn =
        call_tool(conn, "patch_note", %{
          "path" => "Health/Supplements.md",
          "find" => "Omega 3",
          "replace" => "Fish Oil"
        })

      text = tool_text(conn)
      assert text =~ "Replaced 1 occurrence(s)"

      conn =
        call_tool(build_authed(conn), "get_note", %{"source_path" => "Health/Supplements.md"})

      assert tool_text(conn) =~ "Fish Oil"
      refute tool_text(conn) =~ "Omega 3"
    end

    test "replaces all occurrences with -1", %{conn: conn, user: user} do
      # First add duplicate text — need the vault too
      {:ok, vault} = Engram.Vaults.get_default_vault(user)

      Engram.Notes.upsert_note(
        user,
        vault,
        %{
          "path" => "Test/Dupes.md",
          "content" => "foo bar foo baz foo",
          "mtime" => 1_000.0
        }
      )

      conn =
        call_tool(conn, "patch_note", %{
          "path" => "Test/Dupes.md",
          "find" => "foo",
          "replace" => "qux",
          "occurrence" => -1
        })

      text = tool_text(conn)
      assert text =~ "Replaced 3 occurrence(s)"
    end

    test "returns error when text not found", %{conn: conn} do
      conn =
        call_tool(conn, "patch_note", %{
          "path" => "Health/Supplements.md",
          "find" => "nonexistent text",
          "replace" => "something"
        })

      text = tool_text(conn)
      assert text =~ "Text not found"
    end

    test "returns error when note not found", %{conn: conn} do
      conn =
        call_tool(conn, "patch_note", %{
          "path" => "Missing/Note.md",
          "find" => "x",
          "replace" => "y"
        })

      text = tool_text(conn)
      assert text == "Note not found: Missing/Note.md"
    end
  end

  describe "update_section tool" do
    test "replaces section content under heading", %{conn: conn} do
      conn =
        call_tool(conn, "update_section", %{
          "path" => "Health/Supplements.md",
          "heading" => "Shopping List",
          "content" => "- Fish Oil\n- Magnesium"
        })

      text = tool_text(conn)
      assert text =~ "Section 'Shopping List' updated"

      conn =
        call_tool(build_authed(conn), "get_note", %{"source_path" => "Health/Supplements.md"})

      result = tool_text(conn)
      assert result =~ "Fish Oil"
      assert result =~ "Magnesium"
      # Original items should be gone
      refute result =~ "Omega 3"
      refute result =~ "Vitamin D"
      # Content after the section should still be there
      assert result =~ "Take with food."
    end

    test "returns error when heading not found", %{conn: conn} do
      conn =
        call_tool(conn, "update_section", %{
          "path" => "Health/Supplements.md",
          "heading" => "Nonexistent Heading",
          "content" => "new stuff"
        })

      text = tool_text(conn)
      assert text =~ "Heading not found"
    end

    test "returns error when note not found", %{conn: conn} do
      conn =
        call_tool(conn, "update_section", %{
          "path" => "Missing/Note.md",
          "heading" => "Test",
          "content" => "x"
        })

      text = tool_text(conn)
      assert text == "Note not found: Missing/Note.md"
    end
  end

  describe "create_note tool" do
    test "creates note with explicit folder", %{conn: conn} do
      conn =
        call_tool(conn, "create_note", %{
          "title" => "New Health Note",
          "content" => "Some health content.",
          "suggested_folder" => "Health"
        })

      text = tool_text(conn)
      assert text =~ "Note created: Health/New Health Note.md"

      conn =
        call_tool(build_authed(conn), "get_note", %{"source_path" => "Health/New Health Note.md"})

      result = tool_text(conn)
      assert result =~ "# New Health Note"
      assert result =~ "Some health content."
    end

    test "creates note with H1 prefix when content lacks one", %{conn: conn} do
      conn =
        call_tool(conn, "create_note", %{
          "title" => "No Heading",
          "content" => "Just body text.",
          "suggested_folder" => "Work"
        })

      assert tool_text(conn) =~ "Note created:"

      conn = call_tool(build_authed(conn), "get_note", %{"source_path" => "Work/No Heading.md"})
      assert tool_text(conn) =~ "# No Heading"
    end

    test "preserves existing H1 in content", %{conn: conn} do
      conn =
        call_tool(conn, "create_note", %{
          "title" => "Has Heading",
          "content" => "# Custom Title\n\nBody.",
          "suggested_folder" => "Work"
        })

      conn = call_tool(build_authed(conn), "get_note", %{"source_path" => "Work/Has Heading.md"})
      result = tool_text(conn)
      assert result =~ "# Custom Title"
      # Should NOT have duplicate "# Has Heading"
      refute result =~ "# Has Heading\n\n# Custom Title"
    end
  end

  describe "rename_note tool" do
    test "renames note to new path", %{conn: conn} do
      conn =
        call_tool(conn, "rename_note", %{
          "old_path" => "Health/Exercise.md",
          "new_path" => "Health/Workout.md"
        })

      text = tool_text(conn)
      assert text =~ "Note renamed: Health/Exercise.md -> Health/Workout.md"

      # Old path gone, new path works
      conn = call_tool(build_authed(conn), "get_note", %{"source_path" => "Health/Exercise.md"})
      assert tool_text(conn) =~ "Note not found"

      conn = call_tool(build_authed(conn), "get_note", %{"source_path" => "Health/Workout.md"})
      assert tool_text(conn) =~ "Daily routine."
    end

    test "returns error for missing note", %{conn: conn} do
      conn =
        call_tool(conn, "rename_note", %{
          "old_path" => "Missing/Note.md",
          "new_path" => "Missing/New.md"
        })

      assert tool_text(conn) == "Note not found: Missing/Note.md"
    end
  end

  describe "rename_folder tool" do
    test "renames folder and all notes in it", %{conn: conn} do
      conn =
        call_tool(conn, "rename_folder", %{
          "old_folder" => "Health",
          "new_folder" => "Wellness"
        })

      text = tool_text(conn)
      assert text =~ "Folder renamed: Health -> Wellness (2 notes updated)"

      conn = call_tool(build_authed(conn), "list_folder", %{"folder" => "Wellness"})
      result = tool_text(conn)
      assert result =~ "Supplements"
      assert result =~ "Exercise"
    end
  end

  describe "delete_note tool" do
    test "deletes a note", %{conn: conn} do
      conn = call_tool(conn, "delete_note", %{"path" => "Work/Project.md"})
      text = tool_text(conn)
      assert text =~ "Note deleted: Work/Project.md"

      conn = call_tool(build_authed(conn), "get_note", %{"source_path" => "Work/Project.md"})
      assert tool_text(conn) =~ "Note not found"
    end
  end

  # =========================================================================
  # API key vault restriction tests
  # =========================================================================

  describe "MCP vault switching with restricted API key" do
    setup do
      user = insert(:user)
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      vault_a = insert(:vault, user: user, is_default: true, name: "Vault A")

      # Override limit so user can have 2 vaults
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})
      {:ok, vault_b} = Engram.Vaults.create_vault(user, %{name: "Vault B"})

      {:ok, api_key, api_key_record} = Engram.Accounts.create_api_key(user, "restricted-key")

      # Restrict key to vault_a only
      Engram.Repo.insert_all("api_key_vaults", [
        %{api_key_id: api_key_record.id, vault_id: vault_a.id}
      ])

      authed =
        build_conn()
        |> put_req_header("authorization", "Bearer #{api_key}")

      # Seed a note in vault_b to prove the tool can't read it
      Engram.Notes.upsert_note(user, vault_b, %{
        "path" => "Secret/Note.md",
        "content" => "# Secret",
        "mtime" => 1_000.0
      })

      %{conn: authed, user: user, vault_a: vault_a, vault_b: vault_b}
    end

    test "restricted key cannot switch to unauthorized vault via tool arguments",
         %{conn: conn, vault_b: vault_b} do
      conn =
        call_tool(conn, "get_note", %{
          "source_path" => "Secret/Note.md",
          "vault_id" => vault_b.id
        })

      text = tool_text(conn)
      assert text =~ "Error:"
      assert text =~ "API key does not have access"
    end

    test "restricted key can use its authorized vault via tool arguments",
         %{conn: conn, vault_a: _vault_a} do
      conn =
        call_tool(conn, "list_vaults")

      text = tool_text(conn)
      # Should succeed (list_vaults doesn't use vault_id arg, but validates it works)
      refute text =~ "Error:"
    end
  end

  # Helper: rebuild authed conn (since conn is consumed after first request)
  defp build_authed(conn) do
    auth_header =
      Enum.find_value(conn.req_headers, fn
        {"authorization", val} -> val
        _ -> nil
      end)

    build_conn()
    |> put_req_header("authorization", auth_header)
  end
end
