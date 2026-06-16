defmodule Engram.MCP.HandlersSearchModeTest do
  use ExUnit.Case, async: true

  alias Engram.MCP.Handlers

  test "search_notes tool advertises the mode enum" do
    tool = Enum.find(Engram.MCP.Tools.list(), &(&1.name == "search_notes"))
    assert tool.inputSchema["properties"]["mode"]["enum"] == ["hybrid", "keyword", "vector"]
    assert tool.inputSchema["properties"]["mode"]["default"] == "hybrid"
  end

  test "mode arg maps to the Search opt (unknown falls back to hybrid)" do
    assert Handlers.search_mode(%{"mode" => "keyword"}) == :keyword
    assert Handlers.search_mode(%{"mode" => "vector"}) == :vector
    assert Handlers.search_mode(%{"mode" => "nonsense"}) == :hybrid
    assert Handlers.search_mode(%{}) == :hybrid
  end
end
