defmodule EngramWeb.McpPromptsTest do
  @moduledoc """
  MCP prompts: user-invoked templates (slash commands in Claude Code/Desktop)
  that steer the model through our existing tools. Static text, no new data
  paths. Directories (LobeHub) also score a server on whether it has any.
  """
  use EngramWeb.ConnCase, async: true

  alias Engram.MCP.Prompts

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, _vault, _} = Engram.Vaults.register_vault(user, "Test Vault", Ecto.UUID.generate())
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    grant_api_write!(user)

    %{conn: put_req_header(conn, "authorization", "Bearer #{api_key}")}
  end

  defp rpc(conn, method, params \\ %{}) do
    conn
    |> post("/api/mcp", %{"jsonrpc" => "2.0", "id" => 3, "method" => method, "params" => params})
    |> json_response(200)
  end

  test "initialize advertises the prompts capability", %{conn: conn} do
    caps = rpc(conn, "initialize")["result"]["capabilities"]
    assert caps["prompts"] == %{"listChanged" => false}
  end

  test "prompts/list returns every prompt with its arguments", %{conn: conn} do
    prompts = rpc(conn, "prompts/list")["result"]["prompts"]

    assert Enum.map(prompts, & &1["name"]) ==
             ~w(recall save_conversation find_connections capture project_brief tidy_tags organize_folder)

    for p <- prompts do
      assert is_binary(p["title"]) and is_binary(p["description"])

      for a <- p["arguments"] do
        assert is_binary(a["name"]) and is_binary(a["description"])
        assert is_boolean(a["required"])
      end
    end
  end

  test "names follow the tool-name grammar so every client can turn them into commands" do
    for %{"name" => name} <- Prompts.wire_list() do
      assert name =~ ~r/\A[A-Za-z0-9_.-]{1,128}\z/
    end
  end

  test "prompts/get fills the arguments into a user message", %{conn: conn} do
    result = rpc(conn, "prompts/get", %{"name" => "recall", "arguments" => %{"topic" => "CRDTs"}})

    assert [%{"role" => "user", "content" => %{"type" => "text", "text" => text}}] =
             result["result"]["messages"]

    assert text =~ "CRDTs"
    assert text =~ "search_notes"
  end

  test "every prompt renders with its required arguments and names only real tools" do
    tool_names = MapSet.new(Engram.MCP.Tools.wire_list(), & &1["name"])

    for %{"name" => name, "arguments" => args} <- Prompts.wire_list() do
      filled = Map.new(args, &{&1["name"], "x"})

      assert {:ok, %{"messages" => [%{"content" => %{"text" => text}}]}} =
               Prompts.get(name, filled)

      # A prompt that tells the model to call a tool we renamed is a silent break.
      for tool <- Regex.scan(~r/`([a-z_]+)`/, text, capture: :all_but_first) |> List.flatten() do
        assert tool in tool_names, "prompt #{name} references unknown tool #{tool}"
      end
    end
  end

  test "optional arguments may be omitted", %{conn: conn} do
    result = rpc(conn, "prompts/get", %{"name" => "save_conversation"})
    assert [%{"content" => %{"text" => text}}] = result["result"]["messages"]
    assert text =~ "suggest_folder"
  end

  test "an unknown prompt is Invalid params", %{conn: conn} do
    assert %{"error" => %{"code" => -32_602}} = rpc(conn, "prompts/get", %{"name" => "nope"})
  end

  test "a missing required argument is Invalid params", %{conn: conn} do
    assert %{"error" => %{"code" => -32_602, "message" => msg}} =
             rpc(conn, "prompts/get", %{"name" => "recall", "arguments" => %{}})

    assert msg =~ "topic"
  end

  test "non-string or non-map arguments are Invalid params, not a crash", %{conn: conn} do
    assert %{"error" => %{"code" => -32_602}} =
             rpc(conn, "prompts/get", %{"name" => "recall", "arguments" => %{"topic" => 5}})

    assert %{"error" => %{"code" => -32_602}} =
             rpc(conn, "prompts/get", %{"name" => "recall", "arguments" => ["CRDTs"]})

    assert %{"error" => %{"code" => -32_602}} = rpc(conn, "prompts/get", %{"name" => 1})
  end
end
