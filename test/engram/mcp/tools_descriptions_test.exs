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

  # Caveats a client needs before calling: which tools skip vault_id, what a
  # new note looks like, and that link rewrites are not synchronous.
  @caveats %{
    "list_vaults" => ["search_notes"],
    "append_to_note" => ["# <name>"],
    "rename_note" => ["in the background"],
    "write_note" => ["create_note takes a title"]
  }

  for {tool, phrases} <- @caveats, phrase <- phrases do
    test "#{tool} description states #{phrase}" do
      desc = Enum.find(Tools.list(), &(&1.name == unquote(tool))).description
      assert desc =~ unquote(phrase)
    end
  end

  test "no client-visible tool text uses an em dash" do
    for t <- Tools.wire_list(), s <- strings(t) do
      refute s =~ "—", "#{t["name"]} has an em dash: #{s}"
    end
  end

  defp strings(s) when is_binary(s), do: [s]
  defp strings(m) when is_map(m), do: Enum.flat_map(Map.values(m), &strings/1)
  defp strings(l) when is_list(l), do: Enum.flat_map(l, &strings/1)
  defp strings(_), do: []
end
