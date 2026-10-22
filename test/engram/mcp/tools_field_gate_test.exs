defmodule Engram.MCP.ToolsFieldGateTest do
  # `list_fields` and search_notes' `fields` are advertised only when field
  # filters work (`FieldFilters.available?/0`: v5 payload format + v5 layout).
  use EngramWeb.ConnCase, async: true

  alias Engram.MCP.Tools
  alias Engram.ServiceConfig

  defp search_props do
    {:ok, tool} = Tools.get("search_notes")
    tool.inputSchema["properties"]
  end

  describe "flags off (default)" do
    test "list_fields is neither listed nor gettable" do
      refute "list_fields" in Enum.map(Tools.list(), & &1.name)
      refute "list_fields" in Enum.map(Tools.wire_list(), & &1["name"])
      assert Tools.get("list_fields") == :error
    end

    test "search_notes schema has no fields property" do
      refute Map.has_key?(search_props(), "fields")
      assert Map.has_key?(search_props(), "folder")
    end

    test "list_fields call is an unknown tool, and a stray fields arg is ignored" do
      %{conn: conn} = authed_api_conn(%{conn: build_conn()})
      resp = conn |> call_tool("list_fields", %{}) |> json_response(200)
      assert resp["error"]["message"] =~ "Unknown tool"

      conn2 = call_tool(conn, "search_notes", %{"query" => "x", "fields" => []})
      body = json_response(conn2, 200)
      refute inspect(body) =~ "Unknown argument"
      refute inspect(body) =~ "field_filters_unavailable"
    end
  end

  describe "flags on" do
    setup do
      ServiceConfig.put_override(:v5_payload_format, true)
      ServiceConfig.put_override(:write_v5_layout, true)
    end

    test "both are advertised and callable" do
      assert "list_fields" in Enum.map(Tools.list(), & &1.name)
      assert {:ok, _} = Tools.get("list_fields")
      assert Map.has_key?(search_props(), "fields")
    end
  end
end
