defmodule Engram.MCP.ToolsDescriptionsTest do
  # Guards the TDQS Usage Guidelines fix: each overlapping tool names the
  # sibling to use for the cases it does not cover.
  use ExUnit.Case, async: true

  alias Engram.MCP.Tools

  @siblings %{
    "write_note" => ~w(append_to_note patch_note create_note),
    "patch_note" => ~w(update_section append_to_note write_note),
    "update_section" => ~w(patch_note append_to_note),
    "append_to_note" => ~w(patch_note write_note),
    "delete_note" => ~w(delete_folder rename_note),
    "list_folder" => ~w(list_folders search_notes),
    "list_vaults" => ~w(vault_id),
    "rename_note" => ~w(rename_folder move_attachment),
    "rename_folder" => ~w(rename_note)
  }

  for {tool, names} <- @siblings, name <- names do
    test "#{tool} description names #{name}" do
      desc = Enum.find(Tools.list(), &(&1.name == unquote(tool))).description
      assert desc =~ unquote(name)
    end
  end

  test "no description uses an em dash" do
    for t <- Tools.list(), do: refute(t.description =~ "—", "#{t.name} has an em dash")
  end
end
