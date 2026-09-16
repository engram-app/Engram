defmodule EngramWeb.McpVaultRefTest do
  @moduledoc """
  MCP keeps no active-vault state, so every vault-scoped tool takes a
  `vault_id` — and a caller who knows only the vault's NAME had to spend a
  `list_vaults` round trip first just to learn its UUID. Over 30 days of prod
  traffic that discovery tax was ~9% of all MCP tool calls.

  `vault_id` now also accepts a slug or display name. Resolution happens at the
  one place a caller-named vault is turned into a vault, so the credential's
  scope check is unchanged — a name must not reach a vault a UUID could not.
  """
  use EngramWeb.ConnCase, async: true

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)

    # vault_a goes through the public path so its encrypted name really decrypts
    # to "Test Vault". vault_b uses the factory because the default plan caps a
    # user at one registered vault; resolution is slug-based either way.
    {:ok, vault_a, _} = Engram.Vaults.register_vault(user, "Test Vault", Ecto.UUID.generate())
    vault_b = insert(:vault, user: user, slug: "second-vault")

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

    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    grant_api_write!(user)

    %{
      conn: put_req_header(conn, "authorization", "Bearer #{api_key}"),
      user: user,
      vault_a: vault_a,
      vault_b: vault_b
    }
  end

  defp get_note(conn, path, vault_ref) do
    tool_text(call_tool(conn, "get_note", %{"source_path" => path, "vault_id" => vault_ref}))
  end

  describe "vault_id accepts a name" do
    test "resolves a vault by its slug", %{conn: conn} do
      assert get_note(conn, "a.md", "test-vault") =~ "in vault A"
    end

    test "resolves a vault by its display name", %{conn: conn} do
      assert get_note(conn, "a.md", "Test Vault") =~ "in vault A"
    end

    test "resolves a display name regardless of case and spacing", %{conn: conn} do
      assert get_note(conn, "a.md", "test vault") =~ "in vault A"
      assert get_note(conn, "b.md", "SECOND VAULT") =~ "in vault B"
    end

    test "a name selects that vault, not merely the default", %{conn: conn} do
      # vault_a is the default (registered first), so a bare call would hit it.
      # Naming vault_b has to actually move the target.
      assert get_note(conn, "b.md", "Second Vault") =~ "in vault B"
    end

    test "a UUID still resolves", %{conn: conn, vault_a: vault_a} do
      assert get_note(conn, "a.md", vault_a.id) =~ "in vault A"
    end
  end

  describe "set_vault" do
    # set_vault resolves against its own accessible-vaults list rather than
    # through resolve_mcp_vault, so it needs the name path explicitly. A model
    # that probes with set_vault("Engram") and gets "not found" will stop
    # trusting names on the other 19 tools too.
    test "validates a vault named by slug or display name", %{conn: conn, vault_a: vault_a} do
      assert tool_text(call_tool(conn, "set_vault", %{"vault_id" => "Test Vault"})) =~
               to_string(vault_a.id)

      assert tool_text(call_tool(conn, "set_vault", %{"vault_id" => "test-vault"})) =~
               to_string(vault_a.id)
    end

    test "still rejects a name that matches nothing", %{conn: conn} do
      conn = call_tool(conn, "set_vault", %{"vault_id" => "no-such-vault"})

      assert json_response(conn, 200)["result"]["isError"] == true
    end
  end

  describe "unresolvable names" do
    test "an unknown name is a tool error pointing at list_vaults", %{conn: conn} do
      conn =
        call_tool(conn, "get_note", %{"source_path" => "a.md", "vault_id" => "no-such-vault"})

      resp = json_response(conn, 200)

      refute resp["error"], "expected a tool execution error, not a protocol error"
      assert resp["result"]["isError"] == true
      assert tool_text(conn) =~ "list_vaults"
    end

    test "a name that slugifies to nothing does not resolve to some other vault", %{conn: conn} do
      # slugify/1 reduces scripts with no ASCII fallback to "", which must not
      # match a vault whose slug happens to be empty-ish or be treated as absent.
      conn = call_tool(conn, "get_note", %{"source_path" => "a.md", "vault_id" => "日本語"})
      resp = json_response(conn, 200)

      assert resp["result"]["isError"] == true
    end
  end

  describe "scope enforcement" do
    test "a slug cannot reach a vault the credential is not scoped to", %{
      conn: conn,
      user: user,
      vault_a: vault_a
    } do
      user = ensure_external_id(user)
      token = Engram.Accounts.generate_jwt(user, %{"scope" => "mcp", "vault_id" => vault_a.id})

      conn =
        conn
        |> delete_req_header("authorization")
        |> put_req_header("authorization", "Bearer #{token}")
        |> call_tool("get_note", %{"source_path" => "b.md", "vault_id" => "second-vault"})

      resp = json_response(conn, 200)

      refute tool_text(conn) =~ "in vault B"
      assert resp["result"]["isError"] == true || resp["error"]
    end
  end
end
