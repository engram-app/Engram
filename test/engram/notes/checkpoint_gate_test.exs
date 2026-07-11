defmodule Engram.Notes.CheckpointGateTest do
  # Shared process-global atomics counter — not safe to run concurrently with
  # other tests that touch the gate.
  use ExUnit.Case, async: false

  alias Engram.Notes.CheckpointGate

  setup do
    # Reset the gate so each test starts empty, and use a small deterministic
    # limit (test env raises the default to 1000).
    CheckpointGate.reset()
    prev = Application.get_env(:engram, :checkpoint_inline_limit)
    Application.put_env(:engram, :checkpoint_inline_limit, 3)

    on_exit(fn ->
      Application.put_env(:engram, :checkpoint_inline_limit, prev)
      CheckpointGate.reset()
    end)

    :ok
  end

  test "acquire grants up to the limit, then refuses" do
    limit = CheckpointGate.limit()
    for _ <- 1..limit, do: assert(CheckpointGate.acquire() == true)
    assert CheckpointGate.acquire() == false
  end

  test "release frees a slot for the next acquire" do
    limit = CheckpointGate.limit()
    for _ <- 1..limit, do: CheckpointGate.acquire()
    assert CheckpointGate.acquire() == false

    CheckpointGate.release()
    assert CheckpointGate.acquire() == true
  end

  test "a refused acquire does not consume a slot" do
    limit = CheckpointGate.limit()
    for _ <- 1..limit, do: CheckpointGate.acquire()
    # Several refusals in a row.
    for _ <- 1..3, do: assert(CheckpointGate.acquire() == false)
    # Freeing one still yields exactly one grant (refusals rolled back cleanly).
    CheckpointGate.release()
    assert CheckpointGate.acquire() == true
    assert CheckpointGate.acquire() == false
  end

  test "a slot held by a :kill'ed process is auto-reclaimed (no permanent leak)" do
    limit = CheckpointGate.limit()
    # Fill all but one slot from the test process.
    for _ <- 1..(limit - 1), do: assert(CheckpointGate.acquire() == true)

    # Take the last slot from a separate process that we then brutally kill
    # WITHOUT releasing — the try/after release never runs on :kill.
    parent = self()

    {pid, mon} =
      spawn_monitor(fn ->
        send(parent, {:got, CheckpointGate.acquire()})
        Process.sleep(:infinity)
      end)

    assert_receive {:got, true}
    # Gate is now full.
    assert CheckpointGate.acquire() == false

    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^mon, :process, ^pid, :killed}

    # The monitor-driven :DOWN handler reclaims the dead process's slot, so a
    # slot frees up. Poll because the gate's :DOWN and our call are unordered.
    assert eventually(fn -> CheckpointGate.acquire() == true end)
  end

  defp eventually(_fun, 0), do: false

  defp eventually(fun, tries) when tries > 0 do
    if fun.() do
      true
    else
      Process.sleep(5)
      eventually(fun, tries - 1)
    end
  end

  defp eventually(fun), do: eventually(fun, 100)
end
