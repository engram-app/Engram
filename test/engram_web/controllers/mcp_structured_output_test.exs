defmodule EngramWeb.McpStructuredOutputTest do
  @moduledoc """
  Structured tool output (`outputSchema` + `structuredContent`, MCP 2025-06-18).

  Every tool used to return one text blob, so a client had to re-parse our
  markdown back into data. It also left us invisible to programmatic tool
  calling / code mode: the host builds typed functions from each tool's
  `outputSchema`, so a tool without one cannot be composed in a client sandbox.

  Conversion is per-tool. These tests pin the plumbing, the first converted
  tool, and the invariant that ties the two together — a tool that ADVERTISES
  an `outputSchema` must actually return `structuredContent`, because the spec
  makes that a MUST and a client generating types from the schema will break on
  a tool that only sometimes honours it.
  """
  use EngramWeb.ConnCase, async: true

  alias Engram.MCP.Tools

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Test Vault", Ecto.UUID.generate())
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    grant_api_write!(user)

    %{conn: put_req_header(conn, "authorization", "Bearer #{api_key}"), user: user, vault: vault}
  end

  defp result(conn, tool, args \\ %{}) do
    json_response(call_tool(conn, tool, args), 200)["result"]
  end

  describe "tools/list advertises outputSchema" do
    test "list_vaults declares one" do
      {:ok, tool} = Tools.get("list_vaults")

      assert is_map(tool[:outputSchema])
      assert tool.outputSchema["type"] == "object"
    end

    test "the schema reaches the wire, not just the struct", %{conn: conn} do
      conn = post(conn, "/api/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

      listed =
        json_response(conn, 200)["result"]["tools"]
        |> Enum.find(&(&1["name"] == "list_vaults"))

      assert listed["outputSchema"]["type"] == "object"
    end

    test "every declared outputSchema is a JSON Schema object" do
      for tool <- Tools.list(), schema = tool[:outputSchema], not is_nil(schema) do
        assert schema["type"] == "object", "#{tool.name} outputSchema must be an object"
        assert is_map(schema["properties"]), "#{tool.name} outputSchema needs properties"
      end
    end
  end

  describe "structuredContent" do
    test "list_vaults returns the vaults as data, not only as markdown", %{
      conn: conn,
      vault: vault
    } do
      result = result(conn, "list_vaults")

      assert [%{"id" => id, "name" => name, "is_default" => is_default}] =
               result["structuredContent"]["vaults"]

      assert id == to_string(vault.id)
      assert name == "Test Vault"
      assert is_default == true
    end

    test "the text rendering is still there for clients that ignore structure", %{conn: conn} do
      result = result(conn, "list_vaults")

      assert [%{"type" => "text", "text" => text}] = result["content"]
      assert text =~ "Test Vault"
      assert result["isError"] == false
    end

    test "a tool with no outputSchema omits structuredContent entirely", %{conn: conn} do
      # An unconverted tool must not grow an empty/nil key: a client checking
      # `"structuredContent" in result` would read that as structured output.
      refute Map.has_key?(result(conn, "list_tags"), "structuredContent")
    end
  end

  describe "every branch of a converted handler honours its schema" do
    # The sweep below calls each tool ONCE, so it only ever exercises whichever
    # branch that single call lands in. A handler that returns a 2-tuple on some
    # other branch while still advertising an outputSchema passes it — verified
    # by reverting list_vaults to a conditional and watching the suite stay
    # green. Assert the branches directly.
    #
    # The empty branch is live in prod: an OAuth grant scoped away from every
    # vault, a restricted API key, or a brand-new user pre-sync all reach it
    # (see the #729 scoping in dispatch_tool/4). The official TS SDK raises
    # McpError when outputSchema is declared and structuredContent is absent, so
    # this is a hard client failure on the recovery path, not a cosmetic gap.
    test "list_vaults returns structuredContent even with no accessible vaults", %{user: user} do
      assert {:ok, text, structured} = Engram.MCP.Handlers.handle("list_vaults", user, [], %{})

      assert structured == %{"vaults" => []}
      assert text =~ "No vaults"
    end

    test "list_vaults returns structuredContent with vaults present", %{user: user, vault: vault} do
      assert {:ok, _text, structured} =
               Engram.MCP.Handlers.handle("list_vaults", user, [vault], %{})

      assert [%{"id" => id}] = structured["vaults"]
      assert id == to_string(vault.id)
    end
  end

  describe "schema and payload agree" do
    test "every tool advertising an outputSchema returns structuredContent", %{conn: conn} do
      declared = for t <- Tools.list(), not is_nil(t[:outputSchema]), do: t.name

      assert declared != [], "no tool has been converted yet"

      for name <- declared do
        result = result(conn, name)

        assert is_map(result["structuredContent"]),
               "#{name} advertises an outputSchema but returned no structuredContent"

        {:ok, tool} = Tools.get(name)

        for key <- Map.keys(result["structuredContent"]) do
          assert Map.has_key?(tool.outputSchema["properties"], key),
                 "#{name} returned undeclared structuredContent key #{key}"
        end
      end
    end
  end
end
