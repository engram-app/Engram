defmodule Mix.Tasks.Engram.Mcp.ToolsJsonTest do
  use ExUnit.Case, async: true

  @tag :tmp_dir
  test "writes the tools/list payload to the given path", %{tmp_dir: dir} do
    path = Path.join(dir, "tools.json")
    Mix.Tasks.Engram.Mcp.ToolsJson.run([path])

    decoded = path |> File.read!() |> Jason.decode!()
    assert decoded["tools"] == Engram.MCP.Tools.wire_list() |> Jason.encode!() |> Jason.decode!()
    assert File.read!(path) |> String.ends_with?("\n")
  end
end
