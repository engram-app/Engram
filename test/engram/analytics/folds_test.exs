defmodule Engram.Analytics.FoldsTest do
  # The node-local ETS table must not grow with every key ever folded, and a
  # key's counts must never ship without their props. Both hold because a key
  # is ONE row (props and counters together) and add/take/flush are each one
  # atomic ETS op on it, so no interleaving of them can split the row: the
  # only orders are "before" and "after", and these tests run both.
  # DataCase: flush/0 tracks through Engram.Analytics, which reads users.
  use Engram.DataCase, async: false

  alias Engram.Analytics.Folds

  @table :engram_analytics_folds

  defp new_key, do: {"mcp_tool_called", Ecto.UUID.generate(), "list_vaults"}

  defp rows_for(key), do: Enum.filter(:ets.tab2list(@table), &(elem(elem(&1, 0), 0) == key))

  test "add/3 keeps a key's counts and props in one row" do
    key = new_key()
    :ok = Folds.add(key, %{calls: 2, errors: 1}, %{tool: "list_vaults"})

    assert [row] = rows_for(key)
    assert elem(row, 1) == %{tool: "list_vaults"}
    Folds.take(key, [:calls, :errors])
  end

  test "take/2 clears the key's row" do
    key = new_key()
    :ok = Folds.add(key, %{calls: 2, errors: 1}, %{tool: "list_vaults"})

    assert %{calls: 2, errors: 1} = Folds.take(key, [:errors, :calls])
    assert rows_for(key) == []
    assert %{calls: 0} = Folds.take(key, [:calls])
  end

  test "a take between two adds splits the counts, each add's row whole" do
    key = new_key()
    :ok = Folds.add(key, %{calls: 1}, %{tool: "a"})
    assert %{calls: 1} = Folds.take(key, [:calls])

    :ok = Folds.add(key, %{calls: 2}, %{tool: "b"})
    assert [row] = rows_for(key)
    assert elem(row, 1) == %{tool: "b"}
    assert %{calls: 2} = Folds.take(key, [:calls])
    assert rows_for(key) == []
  end

  test "a flush between two adds leaves nothing behind, and the next add is whole" do
    key = new_key()
    :ok = Folds.add(key, %{calls: 1}, %{tool: "a"})
    :ok = Folds.flush()
    assert rows_for(key) == []

    :ok = Folds.add(key, %{calls: 2}, %{tool: "b"})
    assert [row] = rows_for(key)
    assert elem(row, 1) == %{tool: "b"}
    :ok = Folds.flush()
    assert rows_for(key) == []
  end

  # The trade for one atomic op: props are written only when the row is
  # created, so a rollup carries the first occurrence's props since the last
  # send, not the latest.
  test "an add to a pending key adds its counts and keeps the row's props" do
    key = new_key()
    :ok = Folds.add(key, %{calls: 1}, %{tool: "a"})
    :ok = Folds.add(key, %{calls: 2}, %{tool: "b"})

    assert [row] = rows_for(key)
    assert elem(row, 1) == %{tool: "a"}
    assert %{calls: 3} = Folds.take(key, [:calls])
  end
end
