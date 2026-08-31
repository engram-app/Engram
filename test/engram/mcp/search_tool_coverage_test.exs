defmodule Engram.MCP.SearchToolCoverageTest do
  @moduledoc """
  Every MCP tool that runs a search must spend the daily search bucket.

  `Tools.search_tools/0` is a hand-maintained name list, while the
  `Search.search/4` calls live in `Engram.MCP.Handlers`. Nothing fails at
  compile time if a new retrieval tool is added to `Handlers` and not to that
  list — which is structurally the same "the gate exists but does not cover
  this path" bug as the `EnforceSearchCap` plug bypass, moved up one layer.

  So derive the truth from `Handlers` and compare.
  """
  use ExUnit.Case, async: true

  alias Engram.MCP.Tools

  # Tools that reach `Search.search/4` but are deliberately not charged.
  # Empty today: `create_note` / `write_note` search only through the private
  # `auto_place_folder/4`, which this scan does not attribute to a tool (see
  # the moduledoc note on limits below).
  @exempt []

  test "every Handlers clause that searches is in Tools.search_tools/0" do
    charged = MapSet.new(Tools.search_tools())
    exempt = MapSet.new(@exempt)

    uncovered =
      searching_tools()
      |> Enum.reject(&(MapSet.member?(charged, &1) or MapSet.member?(exempt, &1)))

    assert uncovered == [],
           """
           These MCP tools call Engram.Search.search/4 but are not charged to
           the daily search bucket:

             #{Enum.map_join(uncovered, "\n  ", & &1)}

           Add them to `@search_tools` in Engram.MCP.Tools, or to @exempt here
           with a reason. An uncharged retrieval tool is a free-tier bypass.
           """
  end

  test "Tools.search_tools/0 lists no tool that does not search" do
    searching = MapSet.new(searching_tools())

    stale = Enum.reject(Tools.search_tools(), &MapSet.member?(searching, &1))

    assert stale == [],
           """
           These tools are charged to the search bucket but no longer call
           Engram.Search.search/4:

             #{Enum.map_join(stale, "\n  ", & &1)}

           Remove them — charging a tool that does not search burns a Free
           user's allowance for nothing.
           """
  end

  # Tool names whose `def handle("name", ...)` clause body contains a direct
  # `Search.search(...)` call.
  #
  # LIMIT: direct calls only. A clause that searches via a private helper (as
  # `create_note` does through `auto_place_folder/4`) is invisible here. That is
  # acceptable because the helper case is a documented, deliberate exemption;
  # the case this guards is the realistic one — someone adds a new retrieval
  # tool and forgets the list.
  defp searching_tools do
    "lib/engram/mcp/handlers.ex"
    |> File.read!()
    |> Code.string_to_quoted!()
    |> Macro.prewalk([], fn node, acc -> {node, clause_name(node) ++ acc} end)
    |> elem(1)
    |> Enum.uniq()
  end

  defp clause_name({:def, _, [{:handle, _, [name | _]} | _] = body}) when is_binary(name) do
    if searches?(body), do: [name], else: []
  end

  defp clause_name(_), do: []

  defp searches?(ast) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, mods}, :search]}, _, _} = n, _ when is_list(mods) ->
          {n, List.last(mods) == :Search}

        n, acc ->
          {n, acc}
      end)

    found
  end
end
