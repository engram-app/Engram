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
end
