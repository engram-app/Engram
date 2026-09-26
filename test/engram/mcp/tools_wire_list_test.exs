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

  # An undeclared key survives dispatch as a `hidden_params` back-compat
  # alias (edit_note's old_text/new_text), but a client reading only the
  # advertised schema has no way to know that — and no reason to guess it.
  # `additionalProperties: false` tells such a client up front that any key
  # not listed in `properties` will be rejected, without advertising the
  # hidden ones themselves.
  test "wire_list/0 sets additionalProperties: false on every tool's inputSchema" do
    for t <- Tools.wire_list() do
      assert t["inputSchema"]["additionalProperties"] == false,
             "#{t["name"]} inputSchema is missing additionalProperties: false"
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
