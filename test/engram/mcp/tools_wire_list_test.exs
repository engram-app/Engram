defmodule Engram.MCP.ToolsWireListTest do
  use EngramWeb.ConnCase, async: true

  alias Engram.MCP.Tools

  test "wire_list/0 renders every listed tool with string keys and no handler" do
    wire = Tools.wire_list()

    assert length(wire) == length(Tools.list())

    for t <- wire do
      assert Map.keys(t) --
               ["name", "title", "description", "inputSchema", "annotations", "outputSchema"] ==
               []

      assert is_binary(t["name"]) and is_binary(t["description"])
      refute Map.has_key?(t, "handler")
    end
  end

  describe "against the live endpoint" do
    setup :authed_api_conn

    test "wire_list/0 is byte-for-byte what tools/list serves", %{conn: conn} do
      conn =
        post(conn, "/api/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

      served = json_response(conn, 200)["result"]["tools"]
      assert served == Tools.wire_list() |> Jason.encode!() |> Jason.decode!()
    end
  end
end
