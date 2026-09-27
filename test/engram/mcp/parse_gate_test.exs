defmodule Engram.MCP.ParseGateTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Engram.MCP.ParseGate
  alias Engram.MCP.Sections

  # A per-test, unregistered gate: no global app env, no shared state.
  defp gate(limit) do
    start_supervised!({ParseGate, name: nil, limit: limit, max_waiting: 4})
  end

  # Holds one slot of `g` until sent `:go`; returns the worker pid once the
  # slot is actually held (message-based, no sleeps).
  defp hold(g) do
    test = self()

    Task.start(fn ->
      ParseGate.run(
        fn ->
          send(test, {:holding, self()})
          receive do: (:go -> :ok)
        end,
        gate: g,
        parse_timeout: :infinity
      )
    end)

    assert_receive {:holding, worker}, 5_000
    worker
  end

  test "normal calls run the work and return its result" do
    g = gate(2)
    assert ParseGate.run(fn -> 1 + 1 end, gate: g) == {:ok, 2}
    assert {:ok, [%{text: "A"}]} = Sections.headings("## A\n", gate: g)
  end

  test "a third concurrent parse gets the busy error while both slots are held" do
    g = gate(2)
    w1 = hold(g)
    w2 = hold(g)

    assert Sections.headings("## A\n", gate: g, acquire_timeout: 50) == {:error, :busy}
    assert Sections.find("## A\n", "A", 2, gate: g, acquire_timeout: 50) == {:error, :busy}

    send(w1, :go)
    # A slot frees; the next call waits for it instead of failing.
    assert {:ok, [_]} = Sections.headings("## A\n", gate: g, acquire_timeout: 5_000)
    send(w2, :go)
  end

  test "the waiting queue is bounded: past max_waiting a caller is refused at once" do
    g = start_supervised!({ParseGate, name: nil, limit: 1, max_waiting: 0})
    w = hold(g)
    assert ParseGate.run(fn -> :x end, gate: g, acquire_timeout: 5_000) == {:error, :busy}
    send(w, :go)
  end

  test "a slow parse times out for the caller, and its slot frees only when the work ends" do
    g = gate(1)
    test = self()

    slow = fn ->
      send(test, {:slow, self()})
      receive do: (:go -> :done)
    end

    assert ParseGate.run(slow, gate: g, parse_timeout: 20) == {:error, :parse_timeout}
    assert_receive {:slow, worker}

    # The caller gave up, but the work still holds the slot.
    assert ParseGate.run(fn -> :x end, gate: g, acquire_timeout: 20) == {:error, :busy}

    ref = Process.monitor(worker)
    send(worker, :go)
    assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
    assert ParseGate.run(fn -> :x end, gate: g, acquire_timeout: 5_000) == {:ok, :x}
    # The abandoned result never reaches the caller's mailbox.
    refute_received {_, {:done, :done}}
  end

  test "a crashing parse returns a fixable error and releases its slot" do
    g = gate(1)

    capture_log(fn ->
      assert ParseGate.run(fn -> raise "boom" end, gate: g) == {:error, :parse_failed}
    end)

    assert ParseGate.run(fn -> :x end, gate: g, acquire_timeout: 5_000) == {:ok, :x}
  end

  test "a gate that is not running is reported busy, not a crash" do
    assert ParseGate.run(fn -> :x end, gate: :no_such_gate, acquire_timeout: 50) ==
             {:error, :busy}
  end
end
