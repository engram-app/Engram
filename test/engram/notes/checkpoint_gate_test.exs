defmodule Engram.Notes.CheckpointGateTest do
  # Shared process-global atomics counter — not safe to run concurrently with
  # other tests that touch the gate.
  use ExUnit.Case, async: false

  alias Engram.Notes.CheckpointGate

  setup do
    # Reset the counter to a fresh atomics so each test starts empty, and use a
    # small deterministic limit (test env raises the default to 1000).
    CheckpointGate.init()
    prev = Application.get_env(:engram, :checkpoint_inline_limit)
    Application.put_env(:engram, :checkpoint_inline_limit, 3)
    on_exit(fn -> Application.put_env(:engram, :checkpoint_inline_limit, prev) end)
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
end
