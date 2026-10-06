defmodule Engram.ApplicationBootTest do
  use ExUnit.Case, async: true

  alias Engram.Application, as: App

  # A deploy is when index versions change, so a node that runs queues
  # sweeps once at boot instead of waiting for the next cron tick.
  test "a queue-running node queues a reconcile sweep at boot" do
    assert {Task, fun} = App.boot_sweep_child(queues: [maintenance: 2])
    assert is_function(fun, 0)
  end

  # Removing the child from the supervision tree must fail a test, not only
  # changing the function.
  test "the boot sweep starts after Oban in the supervision tree" do
    children = App.children(queues: [maintenance: 2])
    oban = Enum.find_index(children, &match?({Oban, _}, &1))
    sweep = Enum.find_index(children, &match?({Task, _}, &1))

    assert oban && sweep && sweep > oban
  end

  test "a web node (queues: false) and test mode do not" do
    assert App.boot_sweep_child(queues: false) == nil
    assert App.boot_sweep_child(testing: :manual, queues: [maintenance: 2]) == nil
  end
end
