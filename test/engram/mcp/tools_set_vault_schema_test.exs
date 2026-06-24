defmodule Engram.MCP.ToolsSetVaultSchemaTest do
  use ExUnit.Case, async: true

  test "set_vault advertises vault_id as a UUID string, not an integer (#724)" do
    tool = Enum.find(Engram.MCP.Tools.list(), &(&1.name == "set_vault"))
    schema = tool.inputSchema["properties"]["vault_id"]

    assert schema["type"] == "string"
    assert schema["format"] == "uuid"
  end
end
