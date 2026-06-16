defmodule Engram.MCP.HandlersSearchModeTest do
  use ExUnit.Case, async: true

  test "search_notes tool advertises the mode enum" do
    tool = Enum.find(Engram.MCP.Tools.list(), &(&1.name == "search_notes"))
    assert tool.inputSchema["properties"]["mode"]["enum"] == ["hybrid", "keyword", "vector"]
    assert tool.inputSchema["properties"]["mode"]["default"] == "hybrid"
  end

  test "mode arg maps to the Search opt (unknown falls back to hybrid)" do
    assert Engram.MCP.Handlers.search_mode(%{"mode" => "keyword"}) == :keyword
    assert Engram.MCP.Handlers.search_mode(%{"mode" => "vector"}) == :vector
    assert Engram.MCP.Handlers.search_mode(%{"mode" => "nonsense"}) == :hybrid
    assert Engram.MCP.Handlers.search_mode(%{}) == :hybrid
  end
end
