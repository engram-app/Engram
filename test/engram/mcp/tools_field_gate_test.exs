defmodule Engram.MCP.ToolsFieldGateTest do
  # Field filters always work now (every point is written in the v5 layout),
  # so `list_fields` and search_notes' `fields` are always advertised.
  use ExUnit.Case, async: true

  alias Engram.MCP.Tools

  test "list_fields and the search_notes fields param are advertised and callable" do
    assert "list_fields" in Enum.map(Tools.list(), & &1.name)
    assert "list_fields" in Enum.map(Tools.wire_list(), & &1["name"])
    assert {:ok, _} = Tools.get("list_fields")

    {:ok, tool} = Tools.get("search_notes")
    assert Map.has_key?(tool.inputSchema["properties"], "fields")
  end
end
