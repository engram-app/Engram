defmodule Engram.Analytics.FoldsTest do
  # The node-local ETS table must not grow with every key ever folded: a
  # key whose counts an event took leaves nothing behind.
  use ExUnit.Case, async: false

  alias Engram.Analytics.Folds

  @table :engram_analytics_folds

  defp rows_for(key) do
    :ets.match_object(@table, {{:props, key}, :_}) ++
      :ets.match_object(@table, {{key, :_}, :_})
  end

  test "take/2 clears the key's props row along with its counters" do
    key = {"mcp_tool_called", Ecto.UUID.generate(), "list_vaults"}
    :ok = Folds.add(key, %{calls: 2, errors: 1}, %{tool: "list_vaults"})

    assert %{calls: 2, errors: 1} = Folds.take(key, [:calls, :errors])
    assert rows_for(key) == []
  end

  # add/3 is two ETS writes, and a take/2 on another process can land between
  # them. ETS offers no seam to pause there (and its BIFs cannot be call
  # traced), so this pins the ORDER instead: a counter write that raises shows
  # whether props were already written. Props first would let that take strand
  # counts with no props, and their rollup would ship without its tool/surface.
  test "add/3 writes the counters before the props row" do
    key = {"mcp_tool_called", Ecto.UUID.generate(), "list_vaults"}
    true = :ets.insert(@table, {{key, :calls}, :not_a_counter})

    assert_raise ArgumentError, fn -> Folds.add(key, %{calls: 1}, %{tool: "list_vaults"}) end
    assert :ets.lookup(@table, {:props, key}) == []
    :ets.delete(@table, {key, :calls})
  end
end
