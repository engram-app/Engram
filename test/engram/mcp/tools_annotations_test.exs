defmodule Engram.MCP.ToolsAnnotationsTest do
  # The Claude Connectors Directory and the ChatGPT Apps directory both reject a
  # server whose tools lack a `title` and the read/destructive hints. Clients also
  # use `readOnlyHint` to skip the confirmation prompt on reads.
  use ExUnit.Case, async: true

  alias Engram.MCP.Tools

  @read_only ~w(list_vaults set_vault search_notes list_tags list_folders list_folder
                suggest_folder get_note get_notes get_attachment_upload_target)

  # Overwrites or removes content the user wrote.
  @destructive ~w(write_note patch_note update_section delete_note delete_folder)

  test "every tool declares a title and all four hints" do
    for tool <- Tools.all_callable() do
      assert is_binary(tool.title) and tool.title != "", "#{tool.name} has no title"

      for hint <- ~w(readOnlyHint destructiveHint idempotentHint openWorldHint) do
        assert is_boolean(tool.annotations[hint]), "#{tool.name} is missing #{hint}"
      end
    end
  end

  test "read tools are read-only and nothing else is" do
    for tool <- Tools.all_callable() do
      assert tool.annotations["readOnlyHint"] == tool.name in @read_only,
             "#{tool.name} readOnlyHint is wrong"
    end
  end

  test "tools that overwrite or delete content are marked destructive" do
    for tool <- Tools.list() do
      assert tool.annotations["destructiveHint"] == tool.name in @destructive,
             "#{tool.name} destructiveHint is wrong"
    end
  end

  test "no tool reaches outside the user's own vault" do
    for tool <- Tools.list() do
      refute tool.annotations["openWorldHint"], "#{tool.name} claims openWorldHint"
    end
  end
end
