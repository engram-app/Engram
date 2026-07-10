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
    grant_api_write!(user)
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

    test "tools/list returns 18 tools", %{conn: conn} do
      conn = jsonrpc(conn, "tools/list")
      resp = json_response(conn, 200)

      tools = resp["result"]["tools"]
      assert length(tools) == 18

      names = Enum.map(tools, & &1["name"])
      assert "list_vaults" in names
      assert "set_vault" in names
      assert "search_notes" in names
      assert "get_note" in names
      assert "write_note" in names
      assert "delete_note" in names
      assert "patch_note" in names
      assert "update_section" in names
      assert "create_folder" in names
      assert "move_attachment" in names

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
    test "without vault_id explains MCP keeps no active-vault state", %{conn: conn} do
      conn = call_tool(conn, "set_vault")
      text = tool_text(conn)

      # It must NOT claim an active vault was set (MCP is stateless — #985).
      refute text =~ "Active vault:"
      assert text =~ "no active-vault state"
      assert text =~ "list_vaults"
    end

    test "with valid vault_id validates it and echoes the id to thread",
         %{conn: conn, user: user} do
      {:ok, vault} = Engram.Vaults.get_default_vault(user)
      conn = call_tool(conn, "set_vault", %{"vault_id" => vault.id})
      text = tool_text(conn)

      refute text =~ "Active vault:"
      assert text =~ vault.name
      assert text =~ vault.id
    end

    test "with invalid vault_id returns error", %{conn: conn} do
      conn = call_tool(conn, "set_vault", %{"vault_id" => "00000000-0000-0000-0000-000000999999"})
      text = tool_text(conn)

      assert text =~ "Error:"
    end

    test "with a malformed (non-UUID) vault_id returns a clean error, not a cast crash",
         %{conn: conn} do
      conn = call_tool(conn, "set_vault", %{"vault_id" => "not-a-uuid"})
      text = tool_text(conn)

      assert text =~ "Vault not found"
    end
  end

  # =========================================================================
  # Multi-vault selection — regression for #985 (set_vault was cosmetic; reads
  # silently hit the default vault). The account here owns two vaults.
  # =========================================================================

  describe "MCP multi-vault selection (#985)" do
    # Self-contained fresh user (not the single-vault main-setup user, whose
    # vaults_cap is already resolved at 1). Override is inserted BEFORE any
    # create_vault so the cap resolves at 10 from the first call.
    setup do
      user = insert(:user)
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})

      {:ok, default} = Engram.Vaults.create_vault(user, %{name: "Personal"})
      {:ok, vault_b} = Engram.Vaults.create_vault(user, %{name: "Health"})
      {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "multi-key")
      grant_api_write!(user)

      # A note that lives ONLY in the default vault.
      Engram.Notes.upsert_note(user, default, %{
        "path" => "Health/Supplements.md",
        "content" => "# Supplements\n\nOmega 3.",
        "mtime" => 1_000.0
      })

      # A note that lives ONLY in vault_b, in a folder the default vault lacks.
      Engram.Notes.upsert_note(user, vault_b, %{
        "path" => "Journal/Checkup.md",
        "content" => "# Checkup\n\nBlood pressure noted.",
        "mtime" => 1_000.0
      })

      authed = build_conn() |> put_req_header("authorization", "Bearer #{api_key}")
      %{conn: authed, user: user, vault_b: vault_b, default: default}
    end

    test "a navigation read with no vault_id fails loud instead of silently using the default",
         %{conn: conn} do
      conn = call_tool(conn, "list_folders")
      resp = json_response(conn, 200)

      assert resp["result"]["isError"] == true
      text = resp["result"]["content"] |> hd() |> Map.get("text")
      assert text =~ "multiple vaults"
      assert text =~ "list_vaults"
    end

    test "search_notes with no vault_id routes to cross-vault, not the multi-vault guard",
         %{conn: conn} do
      # Unlike navigation reads, a bare search spans every vault the credential
      # can reach. Search execution needs Qdrant/embedder (absent in unit tests),
      # so the tool errors — but crucially NOT with the navigation fail-loud
      # guard, which proves it routed INTO search rather than refusing. The
      # trapped search-unavailable log is expected here and captured.
      {resp, _log} =
        ExUnit.CaptureLog.with_log(fn ->
          call_tool(conn, "search_notes", %{"query" => "anything"}) |> json_response(200)
        end)

      text = resp["result"]["content"] |> hd() |> Map.get("text")
      refute text =~ "multiple vaults"
      refute text =~ "specify which one"
    end

    test "a read targets the requested non-default vault", %{conn: conn, vault_b: vault_b} do
      conn = call_tool(conn, "list_folder", %{"folder" => "Journal", "vault_id" => vault_b.id})
      text = tool_text(conn)

      assert text =~ "Checkup"
      refute text =~ "Error"
    end

    test "requesting vault B does NOT leak the default vault's content",
         %{conn: conn, vault_b: vault_b} do
      # The default vault has Health/Supplements.md; vault_b has no Health folder.
      conn = call_tool(conn, "list_folder", %{"folder" => "Health", "vault_id" => vault_b.id})
      text = tool_text(conn)

      refute text =~ "Supplements"
    end

    test "requesting the default vault explicitly still returns its content",
         %{conn: conn, default: default} do
      conn = call_tool(conn, "list_folder", %{"folder" => "Health", "vault_id" => default.id})
      text = tool_text(conn)

      assert text =~ "Supplements"
    end

    test "an unknown vault_id fails loud (no silent default fallback)", %{conn: conn} do
      conn =
        call_tool(conn, "list_folder", %{
          "folder" => "Health",
          "vault_id" => "00000000-0000-0000-0000-000000000000"
        })

      resp = json_response(conn, 200)
      assert resp["result"]["isError"] == true
      text = resp["result"]["content"] |> hd() |> Map.get("text")
      assert text =~ "Vault not found"
    end

    test "list_vaults advertises every vault for an unrestricted credential",
         %{conn: conn, vault_b: vault_b, default: default} do
      conn = call_tool(conn, "list_vaults")
      text = tool_text(conn)

      assert text =~ to_string(vault_b.id)
      assert text =~ to_string(default.id)
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

  describe "create_folder tool" do
    test "creates an empty folder marker and returns success", %{conn: conn} do
      conn = call_tool(conn, "create_folder", %{"folder" => "Projects"})
      text = tool_text(conn)

      assert text =~ "Projects"
      assert text =~ "Created"
    end

    test "is idempotent — calling twice still succeeds", %{conn: conn} do
      conn = call_tool(conn, "create_folder", %{"folder" => "Ideas"})
      assert tool_text(conn) =~ "Ideas"

      conn = call_tool(conn, "create_folder", %{"folder" => "Ideas"})
      assert tool_text(conn) =~ "Ideas"
    end

    test "rejects empty folder string", %{conn: conn} do
      conn = call_tool(conn, "create_folder", %{"folder" => ""})
      text = tool_text(conn)

      assert text =~ "folder"
    end

    test "rejects missing folder param", %{conn: conn} do
      conn = call_tool(conn, "create_folder", %{})
      text = tool_text(conn)

      assert text =~ "folder"
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

    test "does not re-inject title/tags already in the decrypted body (#731)", %{conn: conn} do
      # Seeded note has frontmatter `tags: [...]` + a `# Supplements` H1.
      conn = call_tool(conn, "get_note", %{"source_path" => "Health/Supplements.md"})
      text = tool_text(conn)

      refute text =~ "**Tags:**", "tags live in frontmatter; must not be re-injected"
      assert Enum.count(String.split(text, "\n"), &(&1 == "# Supplements")) == 1
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
      assert text =~ "Folder renamed: Health -> Wellness (2 notes, 0 attachments updated)"

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
      grant_api_write!(user)

      # Restrict key to vault_a only
      Engram.Repo.insert_all("api_key_vaults", [
        %{api_key_id: Ecto.UUID.dump!(api_key_record.id), vault_id: Ecto.UUID.dump!(vault_a.id)}
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

    test "list_vaults advertises only the vaults the restricted key can use (#729)",
         %{conn: conn, vault_a: vault_a, vault_b: vault_b} do
      conn = call_tool(conn, "list_vaults")
      text = tool_text(conn)

      refute text =~ "Error:"
      assert text =~ to_string(vault_a.id)
      # vault_b is restricted away — it must NOT announce itself to this key.
      refute text =~ to_string(vault_b.id)
    end

    test "restricted key with no vault_id resolves to its single permitted vault",
         %{conn: conn} do
      # user owns 2 vaults but the key can reach only vault_a → unambiguous,
      # so a bare read must succeed (not fail-loud) and hit vault_a.
      conn = call_tool(conn, "list_folders")
      text = tool_text(conn)

      refute text =~ "multiple vaults"
      refute text =~ "Error:"
    end

    test "set_vault cannot confirm a vault the restricted key can't reach (#729)",
         %{conn: conn, vault_b: vault_b} do
      conn = call_tool(conn, "set_vault", %{"vault_id" => vault_b.id})
      text = tool_text(conn)

      # Refused, and it must not echo vault B as a valid/named vault.
      assert text =~ "Error:"
      assert text =~ "not accessible"
      refute text =~ "is valid"
    end
  end

  # =========================================================================
  # Cross-vault search must not leak vaults a restricted credential can't reach.
  # A key permitted to a >1 SUBSET of the user's vaults cannot cross-vault
  # search (Qdrant has no multi-vault filter), so it must be told to choose one
  # rather than silently searching every vault (#729 privacy boundary).
  # =========================================================================

  describe "cross-vault search privacy for a subset-restricted key" do
    setup do
      user = insert(:user)
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})

      {:ok, va} = Engram.Vaults.create_vault(user, %{name: "A"})
      {:ok, vb} = Engram.Vaults.create_vault(user, %{name: "B"})
      {:ok, _vc} = Engram.Vaults.create_vault(user, %{name: "C"})

      {:ok, api_key, key_rec} = Engram.Accounts.create_api_key(user, "subset-key")
      grant_api_write!(user)

      # Permit the key to A and B only — NOT C. accessible = 2, total = 3.
      Engram.Repo.insert_all("api_key_vaults", [
        %{api_key_id: Ecto.UUID.dump!(key_rec.id), vault_id: Ecto.UUID.dump!(va.id)},
        %{api_key_id: Ecto.UUID.dump!(key_rec.id), vault_id: Ecto.UUID.dump!(vb.id)}
      ])

      %{conn: build_conn() |> put_req_header("authorization", "Bearer #{api_key}")}
    end

    test "bare search on a >1 vault subset refuses to cross-vault (asks to choose)",
         %{conn: conn} do
      conn = call_tool(conn, "search_notes", %{"query" => "anything"})
      resp = json_response(conn, 200)
      text = resp["result"]["content"] |> hd() |> Map.get("text")

      assert resp["result"]["isError"] == true
      assert text =~ "limited to specific vaults"
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

  # ---------------------------------------------------------------------------
  # Trapped tool-handler errors. Regression for the prod 5xx: a tool raised a
  # function_clause error, the catch trapped it, then the formatter called
  # Exception.message/1 on the bare :function_clause atom — which itself has no
  # clause for an atom and raised, escaping the trap into a 500. The formatter
  # must (1) never crash on a non-exception reason and (2) never embed the
  # offending term in the client message (it can carry decrypted %Note{} data).
  # ---------------------------------------------------------------------------
  describe "safe_trapped_message/3" do
    test "returns a safe string for a bare error reason instead of crashing" do
      msg = EngramWeb.McpController.safe_trapped_message(:error, :function_clause, [])

      assert is_binary(msg)
      assert msg =~ "FunctionClauseError"
    end

    test "does not leak the offending term for an exception that carries data" do
      secret = "SUPER_SECRET_DECRYPTED_NOTE_BODY"

      reason =
        try do
          Map.fetch!(%{unrelated: secret}, :missing_key)
        rescue
          e -> e
        end

      msg = EngramWeb.McpController.safe_trapped_message(:error, reason, [])

      assert is_binary(msg)
      refute msg =~ secret
      assert msg =~ "KeyError"
    end

    test "does not leak a tuple reason term carrying decrypted data" do
      secret = "DECRYPTED_NOTE_FROM_CRYPTO_PATH"

      msg = EngramWeb.McpController.safe_trapped_message(:error, {:badmatch, %{body: secret}}, [])

      assert is_binary(msg)
      refute msg =~ secret
      assert msg =~ "MatchError"
    end

    test "exit and throw return generic messages without the reason term" do
      assert EngramWeb.McpController.safe_trapped_message(:exit, {:shutdown, :secret_detail}, []) ==
               "Process exited"

      assert EngramWeb.McpController.safe_trapped_message(:throw, %{secret: "leak"}, []) ==
               "Unexpected throw"
    end
  end

  describe "run_tool_handler/4 trap path" do
    test "a crashing handler returns a clean error and logs the tool name" do
      crashing = %{
        name: "search_notes",
        handler: fn _user, _vault, _args -> :erlang.error(:function_clause) end
      }

      {{result, status, _bytes}, log} =
        ExUnit.CaptureLog.with_log(fn ->
          EngramWeb.McpController.run_tool_handler(crashing, :user, :vault, %{})
        end)

      # No 500 — the trap produces a structured MCP error result, not a raise.
      assert status == :error
      {:ok, payload} = result
      assert payload["isError"] == true
      assert hd(payload["content"])["text"] =~ "Tool execution failed (FunctionClauseError)"

      # The server-side log must name the tool so future occurrences are
      # diagnosable (the original stacktrace is trapped and otherwise lost).
      assert log =~ "mcp tool dispatch trapped"
      assert log =~ "search_notes"
    end
  end
end
