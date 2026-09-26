defmodule Engram.MCP.ToolsSetVaultSchemaTest do
  use ExUnit.Case, async: true

  test "set_vault advertises vault_id as a string, not an integer (#724)" do
    assert vault_id_schema("set_vault")["type"] == "string"
  end

  # #724 pinned `format: "uuid"` alongside the string type. The type is the part
  # that fixed the bug — clients were sending integers. The format is now wrong:
  # the field accepts a vault NAME as well as a UUID, and a strict client that
  # honours `format` would reject a valid name before it ever reached us.
  test "no vault_id field advertises a uuid format, since names are accepted" do
    for tool <- Engram.MCP.Tools.all_callable(),
        schema = tool.inputSchema["properties"]["vault_id"],
        is_map(schema) do
      refute schema["format"] == "uuid",
             "#{tool.name} still advertises vault_id as format: uuid"

      assert schema["type"] == "string", "#{tool.name} must accept vault_id as a string"
    end
  end

  defp vault_id_schema(name) do
    {:ok, tool} = Engram.MCP.Tools.get(name)
    get_in(tool, [Access.key!(:inputSchema), "properties", "vault_id"])
  end
end
