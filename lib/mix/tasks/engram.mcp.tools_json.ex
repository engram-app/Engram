defmodule Mix.Tasks.Engram.Mcp.ToolsJson do
  @shortdoc "Writes the MCP tools/list payload to mcp-tools.json"

  @moduledoc """
  Snapshots the exact `tools/list` payload (`Engram.MCP.Tools.wire_list/0`)
  so CI can lint it with TDQS without starting the app or a database.

  Usage: `mix engram.mcp.tools_json [path]` (default `mcp-tools.json`).
  Regenerate and commit whenever a tool definition changes; CI fails when the
  committed file is stale.
  """

  use Mix.Task

  @default_path "mcp-tools.json"

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("compile")
    path = List.first(argv) || @default_path
    json = Jason.encode!(%{"tools" => Engram.MCP.Tools.wire_list()}, pretty: true)
    File.write!(path, json <> "\n")
    Mix.shell().info("wrote #{path}")
  end
end
