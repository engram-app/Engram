defmodule Engram.Sync.PageGateTest do
  @moduledoc """
  Bounds how many full-content catch-up pages this node builds at once.

  The byte budget caps ONE page. This caps how many of those exist
  simultaneously, so a thundering herd of first syncs degrades into a queue
  instead of stacking N pages of memory on an 820 MB container.

  It must QUEUE, never reject. The client's `walkOpLog` throws `OpLogFetchError`
  on a rejected fetch and aborts the whole walk, so a "busy, try later" reply
  would turn load into the stalled-first-sync bug we just spent a day fixing.
  """
  use ExUnit.Case, async: false

  alias Engram.Sync.PageGate

  setup do
    name = :"gate_#{System.unique_integer([:positive])}"
    start_supervised!({PageGate, name: name, limit: 2})
    %{gate: name}
  end

  defp hold(gate, ref, test_pid) do
    spawn(fn ->
      PageGate.with_slot(
        fn ->
          send(test_pid, {:acquired, ref})
          receive do: (:release -> :ok)
        end,
        gate: gate
      )
    end)
  end

  test "grants up to the limit immediately and makes the next one wait", %{gate: gate} do
    me = self()
    a = hold(gate, :a, me)
    b = hold(gate, :b, me)

    assert_receive {:acquired, :a}, 1000
    assert_receive {:acquired, :b}, 1000

    _c = hold(gate, :c, me)
    refute_receive {:acquired, :c}, 300, "third page ran while both slots were held"

    send(a, :release)
    assert_receive {:acquired, :c}, 1000, "a freed slot was not handed to the waiter"

    send(b, :release)
  end

  test "a holder that crashes frees its slot", %{gate: gate} do
    me = self()
    a = hold(gate, :a, me)
    b = hold(gate, :b, me)
    assert_receive {:acquired, :a}, 1000
    assert_receive {:acquired, :b}, 1000

    # Not a graceful release — the page-building process dies mid-work, which is
    # what an OOM or a channel crash looks like. A leaked slot here would shrink
    # capacity permanently until restart.
    Process.exit(a, :kill)

    _c = hold(gate, :c, me)
    assert_receive {:acquired, :c}, 1000, "the killed holder leaked its slot"

    send(b, :release)
  end

  test "returns the function's value", %{gate: gate} do
    assert PageGate.with_slot(fn -> {:ok, 42} end, gate: gate) == {:ok, 42}
  end

  test "degrades OPEN when the wait times out rather than failing the sync", %{gate: gate} do
    me = self()
    a = hold(gate, :a, me)
    b = hold(gate, :b, me)
    assert_receive {:acquired, :a}, 1000
    assert_receive {:acquired, :b}, 1000

    # Both slots held and no timely release. The gate is a smoother, not a
    # correctness boundary: raising here would crash the channel and strand the
    # sync, which is strictly worse than one unbounded page.
    assert PageGate.with_slot(fn -> :ran_anyway end, gate: gate, timeout: 50) == :ran_anyway

    send(a, :release)
    send(b, :release)
  end
end
