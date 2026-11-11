defmodule Engram.Backfill.ThrottleTest do
  use Engram.DataCase, async: false

  alias Engram.Backfill.Throttle
  alias Engram.ServiceConfig
  alias Engram.Test.FakePressure

  describe "wait_ms/5, the writes-per-second ceiling" do
    # A simulated pass on an injected clock: each window writes `per_window`
    # rows in `work_ms`, then sleeps what `wait_ms/5` says. At every window's
    # end the pass is at or under its ceiling.
    defp simulate(per_s, per_window, work_ms, pause_ms, windows) do
      Enum.reduce(1..windows, {0, 0}, fn _, {now, writes} ->
        writes = writes + per_window
        now = now + work_ms
        now = now + Throttle.wait_ms(0, writes, per_s, pause_ms, now)
        assert writes * 1000 <= per_s * now, "#{writes} writes in #{now} ms"
        {now, writes}
      end)
    end

    test "a pass never exceeds N writes a second" do
      for {per_s, per_window, work_ms} <- [
            {150, 200, 30},
            {150, 1, 0},
            {1, 7, 5},
            {10_000, 200, 1}
          ] do
        simulate(per_s, per_window, work_ms, 0, 200)
      end
    end

    test "the wait is the deficit, never under the pause" do
      # 300 writes at 150/s need 2,000 ms; 500 have passed.
      assert Throttle.wait_ms(0, 300, 150, 250, 500) == 1_500
      # Already slower than the ceiling: just the pause.
      assert Throttle.wait_ms(0, 10, 150, 250, 5_000) == 250
      assert Throttle.wait_ms(0, 0, 150, 0, 0) == 0
    end
  end

  describe "pressure/0" do
    setup do
      on_exit(&FakePressure.reset/0)
    end

    test "nil while the database has room" do
      assert Throttle.pressure() == nil
    end

    test "a long open transaction or a slow pool queue holds a hop" do
      FakePressure.set(%{xact_s: 121})
      assert Throttle.pressure() == :long_xact

      FakePressure.set(%{queue_ms: 201})
      assert Throttle.pressure() == :pool_queue
    end

    test "the bounds are service settings" do
      FakePressure.set(%{xact_s: 30})
      assert Throttle.pressure() == nil
      ServiceConfig.put_override(:backfill_max_xact_s, 10)
      assert Throttle.pressure() == :long_xact
    end

    test "the real probe reads a queue time and a transaction age" do
      assert %{queue_ms: q, xact_s: x} = Throttle.read(Engram.Repo)
      assert is_integer(q) and q >= 0 and is_integer(x) and x >= 0
    end
  end

  @tag :capture_log
  test "positive/2 falls back to its default on a bad setting" do
    ServiceConfig.put_override(:name_terms_backfill_max_rows, 0)
    assert Throttle.positive(:name_terms_backfill_max_rows, 7) == 7
    ServiceConfig.put_override(:name_terms_backfill_max_rows, 3)
    assert Throttle.positive(:name_terms_backfill_max_rows, 7) == 3
  end
end
