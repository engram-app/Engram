defmodule Engram.MCP.ToolsDescriptionsTest do
  # Guards the TDQS Usage Guidelines fix: each overlapping tool names the
  # sibling to use for the cases it does not cover.
  use ExUnit.Case, async: true

  alias Engram.MCP.Tools

  @siblings %{
    "write_note" => ~w(append_to_note edit_note create_note),
    "edit_note" => ~w(append_to_note write_note),
    "append_to_note" => ~w(edit_note write_note),
    "delete_note" => ~w(delete_folder rename_note),
    "list_folder" => ~w(search_notes),
    "list_vaults" => ~w(vault_id),
    "rename_note" => ~w(rename_folder move_attachment),
    "rename_folder" => ~w(rename_note)
  }

  for {tool, names} <- @siblings, name <- names do
    test "#{tool} description names #{name}" do
      {:ok, tool_def} = Tools.get(unquote(tool))
      assert tool_def.description =~ unquote(name)
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
      {:ok, tool_def} = Tools.get(unquote(tool))
      assert tool_def.description =~ unquote(phrase)
    end
  end

  test "no client-visible tool text uses an em dash" do
    for t <- Tools.wire_list(), s <- strings(t) do
      refute s =~ "—", "#{t["name"]} has an em dash: #{s}"
    end
  end

  # Task 3.6: a listed tool must never point a client at a retired name.
  # Word-boundary matched: "get_note" must not false-positive on "get_notes".
  @retired_name_patterns [
    ~r/\bget_note\b/,
    ~r/\blist_folders\b/,
    ~r/\bpatch_note\b/,
    ~r/\bupdate_section\b/,
    ~r/\bset_vault\b/
  ]

  test "no listed tool description or schema text mentions a retired name" do
    for t <- Tools.wire_list(), s <- strings(t), pattern <- @retired_name_patterns do
      refute s =~ pattern, "#{t["name"]} mentions a retired tool: #{s}"
    end
  end

  defp strings(s) when is_binary(s), do: [s]
  defp strings(m) when is_map(m), do: Enum.flat_map(Map.values(m), &strings/1)
  defp strings(l) when is_list(l), do: Enum.flat_map(l, &strings/1)
  defp strings(_), do: []
end
