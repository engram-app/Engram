defmodule EngramWeb.McpVaultRefAdversarialTest do
  @moduledoc """
  Regression tests from the adversarial review of the vault-name resolution
  path. Each one reproduced a real defect before its fix landed.

  Note the `Logger.configure(level: :info)` in the handshake describe block.
  `Logger.info/2` is a MACRO that does not evaluate its arguments when the level
  is disabled, and the test env runs at `:warning` — so `handshake_metadata/1`
  is never called by an ordinary controller test, and a request that 500s in
  prod returns a cheerful 200 here. Every assertion about handshake metadata has
  to either call the function directly or raise the level first.
  """
  use EngramWeb.ConnCase, async: false

  alias EngramWeb.McpController

  require Logger

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault_a, _} = Engram.Vaults.register_vault(user, "Test Vault", Ecto.UUID.generate())
    vault_b = insert(:vault, user: user, slug: "second-vault")

    {:ok, _} =
      Engram.Notes.upsert_note(user, vault_b, %{
        "path" => "b.md",
        "content" => "SECRET-IN-VAULT-B",
        "mtime" => 1.0
      })

    {:ok, api_key, key_row} = Engram.Accounts.create_api_key(user, "test-key")
    grant_api_write!(user)

    %{
      conn: put_req_header(conn, "authorization", "Bearer #{api_key}"),
      user: user,
      vault_a: vault_a,
      key_row: key_row
    }
  end

  defp restrict_key_to!(key_row, vault) do
    Engram.Repo.insert_all("api_key_vaults", [
      %{api_key_id: Ecto.UUID.dump!(key_row.id), vault_id: Ecto.UUID.dump!(vault.id)}
    ])
  end

  describe "cross-tenant isolation" do
    test "another user's vault never resolves by name, slug or UUID", %{conn: conn} do
      victim = insert(:user)
      {:ok, victim} = Engram.Crypto.ensure_user_dek(victim)
      {:ok, vv, _} = Engram.Vaults.register_vault(victim, "Victim Vault", Ecto.UUID.generate())

      {:ok, _} =
        Engram.Notes.upsert_note(victim, vv, %{
          "path" => "v.md",
          "content" => "VICTIM-PLAINTEXT",
          "mtime" => 1.0
        })

      for ref <- ["Victim Vault", "victim-vault", to_string(vv.id)] do
        conn = call_tool(conn, "get_note", %{"source_path" => "v.md", "vault_id" => ref})

        refute tool_text(conn) =~ "VICTIM-PLAINTEXT", "leaked via #{ref}"
        assert json_response(conn, 200)["result"]["isError"] == true
      end
    end
  end

  describe "restricted credentials must not become a name oracle" do
    # Once vault_id accepts a NAME, a message that distinguishes "exists but
    # denied" from "no such vault" turns a dictionary into an enumeration
    # oracle against the account's other vault names — which are encrypted at
    # rest precisely because they are sensitive. Under a UUID-only lookup the
    # same branch was harmless: you had to guess a v4.
    test "the refusal is identical for a real vault and an invented one", %{
      conn: conn,
      vault_a: vault_a,
      key_row: key_row
    } do
      restrict_key_to!(key_row, vault_a)

      real =
        tool_text(
          call_tool(conn, "get_note", %{"source_path" => "b.md", "vault_id" => "Second Vault"})
        )

      fake =
        tool_text(
          call_tool(conn, "get_note", %{"source_path" => "b.md", "vault_id" => "Nope Vault"})
        )

      refute real =~ "SECRET-IN-VAULT-B"

      assert String.replace(real, "Second Vault", "X") == String.replace(fake, "Nope Vault", "X"),
             "restricted credential can distinguish a real vault name from an invented one:\n  #{real}\n  #{fake}"
    end

    test "set_vault refuses both the same way too", %{
      conn: conn,
      vault_a: vault_a,
      key_row: key_row
    } do
      restrict_key_to!(key_row, vault_a)

      real = tool_text(call_tool(conn, "set_vault", %{"vault_id" => "Second Vault"}))
      fake = tool_text(call_tool(conn, "set_vault", %{"vault_id" => "Nope Vault"}))

      assert String.replace(real, "Second Vault", "X") == String.replace(fake, "Nope Vault", "X")
    end
  end

  describe "a UUID string is itself a valid slug" do
    # `@slug_format` is alphanumeric groups joined by hyphens, which a UUID
    # satisfies. The UUID branch must not be exclusive: `set_vault` tries both
    # forms ungated, so an exclusive branch made it confirm refs every other
    # tool rejected.
    test "a vault named like a UUID resolves on both paths", %{conn: conn, user: user} do
      uuidish = "550e8400-e29b-41d4-a716-446655440000"
      v = insert(:vault, user: user, slug: uuidish)

      {:ok, _} =
        Engram.Notes.upsert_note(user, v, %{
          "path" => "u.md",
          "content" => "IN-UUIDISH-VAULT",
          "mtime" => 1.0
        })

      assert tool_text(
               call_tool(conn, "get_note", %{"source_path" => "u.md", "vault_id" => uuidish})
             ) =~
               "IN-UUIDISH-VAULT"

      assert tool_text(call_tool(conn, "set_vault", %{"vault_id" => uuidish})) =~ to_string(v.id)
    end
  end

  describe "ambiguous names refuse rather than guess" do
    test "two vaults sharing a name are named as candidates, not silently picked", %{
      conn: conn,
      user: user
    } do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
      {:ok, a, _} = Engram.Vaults.register_vault(user, "Notes", Ecto.UUID.generate())
      {:ok, b, _} = Engram.Vaults.register_vault(user, "Notes", Ecto.UUID.generate())

      conn = call_tool(conn, "get_note", %{"source_path" => "x.md", "vault_id" => "Notes"})
      text = tool_text(conn)

      assert json_response(conn, 200)["result"]["isError"] == true
      assert text =~ to_string(a.id)
      assert text =~ to_string(b.id)
      assert text =~ "slug"
    end

    test "a restricted credential is NOT told the name is ambiguous", %{
      conn: conn,
      user: user,
      vault_a: vault_a,
      key_row: key_row
    } do
      # Naming the candidates is actionable for a credential that can already
      # list every vault. For a restricted one it re-opens the enumeration
      # oracle, so it must get the same scope-shaped refusal as anything else.
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
      {:ok, _, _} = Engram.Vaults.register_vault(user, "Notes", Ecto.UUID.generate())
      {:ok, _, _} = Engram.Vaults.register_vault(user, "Notes", Ecto.UUID.generate())
      restrict_key_to!(key_row, vault_a)

      ambiguous =
        tool_text(call_tool(conn, "get_note", %{"source_path" => "x.md", "vault_id" => "Notes"}))

      invented =
        tool_text(call_tool(conn, "get_note", %{"source_path" => "x.md", "vault_id" => "Nope"}))

      refute ambiguous =~ "vaults are named"

      assert String.replace(ambiguous, "Notes", "X") == String.replace(invented, "Nope", "X"),
             "ambiguity leaked to a restricted credential:\n  #{ambiguous}\n  #{invented}"
    end

    test "set_vault refuses an ambiguous name too", %{conn: conn, user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
      {:ok, a, _} = Engram.Vaults.register_vault(user, "Notes", Ecto.UUID.generate())
      {:ok, b, _} = Engram.Vaults.register_vault(user, "Notes", Ecto.UUID.generate())

      conn = call_tool(conn, "set_vault", %{"vault_id" => "Notes"})
      text = tool_text(conn)

      assert json_response(conn, 200)["result"]["isError"] == true
      assert text =~ to_string(a.id)
      assert text =~ to_string(b.id)
    end
  end

  describe "handshake fields are bounded in BYTES" do
    test "a grapheme bomb cannot inflate the log line", _ do
      # `String.slice/3` counts graphemes and a cluster is unbounded, so 64
      # clusters of "a" + 5,000 combining marks sailed through a 64-"char" cap
      # at full size — one authenticated handshake became megabytes of ingest.
      bomb = String.duplicate("a" <> String.duplicate("́", 5_000), 64)

      total =
        McpController.handshake_metadata(%{
          "protocolVersion" => bomb,
          "clientInfo" => %{"name" => bomb, "version" => bomb}
        })
        |> Keyword.take([:mcp_protocol_requested, :mcp_client_name, :mcp_client_version])
        |> Enum.map(fn {_k, v} -> byte_size(v) end)
        |> Enum.sum()

      assert total < 1_000, "handshake fields not byte-bounded: #{total} bytes"
    end

    test "an ordinary name is still reported verbatim", _ do
      meta = McpController.handshake_metadata(%{"clientInfo" => %{"name" => "claude-code"}})

      assert meta[:mcp_client_name] == "claude-code"
    end
  end

  describe "handshake survives non-plain-map params" do
    # The endpoint parses :multipart with `pass: ["*/*"]`, so an authenticated
    # multipart POST naming a file field `params[clientInfo]` lands a
    # %Plug.Upload{} here. A struct matches `%{}` but has no Access impl.
    test "a struct in place of clientInfo does not raise", _ do
      upload = %Plug.Upload{path: "/tmp/x", filename: "x", content_type: "text/plain"}

      assert McpController.handshake_metadata(%{"clientInfo" => upload})[:mcp_client_name] ==
               "unknown"
    end

    test "a struct in place of params does not raise", _ do
      upload = %Plug.Upload{path: "/tmp/x", filename: "x", content_type: "text/plain"}

      assert McpController.handshake_metadata(upload)[:mcp_protocol_requested] == "unknown"
    end

    test "the crash path is reachable end to end, with logging actually on", %{conn: conn} do
      # Guards against the vacuous-test trap in this file's moduledoc: at the
      # default :warning level this request returns 200 even when the metadata
      # builder raises, because Logger.info never evaluates its argument.
      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)

      conn =
        post(conn, "/api/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"clientInfo" => %{"name" => ["not", "a", "string"]}}
        })

      assert json_response(conn, 200)["result"]["protocolVersion"]
    end
  end
end
