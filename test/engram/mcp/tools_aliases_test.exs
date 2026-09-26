defmodule Engram.MCP.ToolsAliasesTest do
  use ExUnit.Case, async: true

  alias Engram.MCP.Tools

  @retired %{
    "get_note" => "get_notes",
    "list_folders" => "list_folder",
    "patch_note" => "edit_note",
    "update_section" => "edit_note",
    "set_vault" => "list_vaults"
  }

  test "retired tools are not listed" do
    listed = Enum.map(Tools.list(), & &1.name)
    for {old, _} <- @retired, do: refute(old in listed, "#{old} is still listed")
    assert length(listed) == 17
  end

  test "retired tools still resolve through get/1 and name their replacement" do
    for {old, new} <- @retired do
      assert {:ok, tool} = Tools.get(old)
      assert tool.deprecated_for == new
    end
  end

  test "an unknown name still does not resolve" do
    assert Tools.get("no_such_tool") == :error
  end
end
