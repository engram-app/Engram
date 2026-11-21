defmodule Engram.Logs.BudgetDropsTest do
  # async: false: the tally is one node-global table and flush/0 drains all of it.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Engram.Crypto.HMAC
  alias Engram.Logs.BudgetDrops

  setup do
    _ = capture_log(fn -> BudgetDrops.flush() end)
    :ok
  end

  defp budget_lines(log),
    do: log |> String.split("\n") |> Enum.filter(&(&1 =~ "client log budget exceeded"))

  test "one line per device per flush, carrying the dropped lines summed over the window" do
    user_id = Ecto.UUID.generate()

    BudgetDrops.add(user_id, "dev-a", 20)
    BudgetDrops.add(user_id, "dev-a", 20)
    BudgetDrops.add(user_id, "dev-a", 3)
    BudgetDrops.add(user_id, "dev-b", 1)

    log = capture_log([metadata: [:user_id, :device_id, :dropped]], &BudgetDrops.flush/0)
    lines = budget_lines(log)

    assert length(lines) == 2
    dev_a = Enum.find(lines, &(&1 =~ "device_id=#{HMAC.hash_id("dev-a")}"))
    assert dev_a =~ "dropped=43"
    assert dev_a =~ "user_id=#{HMAC.hash_user_id(user_id)}"
    assert Enum.find(lines, &(&1 =~ "device_id=#{HMAC.hash_id("dev-b")}")) =~ "dropped=1"

    # Raw ids never reach the line.
    refute log =~ user_id
    refute log =~ "device_id=dev-a"
  end

  test "a flush with nothing dropped since the last one logs nothing" do
    BudgetDrops.add(Ecto.UUID.generate(), "dev-a", 5)
    _ = capture_log(&BudgetDrops.flush/0)

    assert budget_lines(capture_log(&BudgetDrops.flush/0)) == []
  end
end
