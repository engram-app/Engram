defmodule Engram.Notes.CrdtCheckpointTimerTest do
  @moduledoc """
  Pure unit tests for `CrdtCheckpointTimer.compute_delay/2` — the scheduling
  decision that controls how soon a CRDT edit materializes into the plaintext
  `notes.content` (via a checkpoint).

  No room / DB / wall-clock: `compute_delay/2` is a pure function of the timer
  state + a `now` monotonic stamp, so these are fast and deterministic.
  """
  use ExUnit.Case, async: true

  alias Engram.Notes.CrdtCheckpointTimer

  # Eager < settle so the eager path is observable; ceiling well above both.
  @cfg %{settle_ms: 1_000, ceiling_ms: 5_000, eager_ms: 100}

  defp state(overrides) do
    Map.merge(
      Map.merge(@cfg, %{last_activity_at: nil, first_dirty_at: nil}),
      Map.new(overrides)
    )
  end

  describe "compute_delay/2 — eager first flush" do
    test "the first edit of a quiet note schedules an eager flush" do
      {delay, first_dirty_at} =
        CrdtCheckpointTimer.compute_delay(
          state(last_activity_at: nil, first_dirty_at: nil),
          10_000
        )

      assert delay == 100
      assert first_dirty_at == 10_000
    end

    test "an edit after a full idle gap (>= settle) is treated as quiet -> eager" do
      # last edit was exactly settle_ms ago: the note went quiet and flushed.
      {delay, _} =
        CrdtCheckpointTimer.compute_delay(
          state(last_activity_at: 9_000, first_dirty_at: nil),
          10_000
        )

      assert delay == 100
    end
  end

  describe "idle?/2 — the drain gate (#1152)" do
    test "a room that has never been written to is idle, so it can drain" do
      assert CrdtCheckpointTimer.idle?(%{last_activity_at: nil}, 10_000)
    end

    test "a full idle window since the last write is idle" do
      assert CrdtCheckpointTimer.idle?(
               %{last_activity_at: 9_000, idle_exit_ms: 1_000},
               10_000
             )
    end

    # The race this gate exists for: an :idle_drain already in the mailbox when
    # an :activity lands is still processed AFTER it (cancel_timer cannot
    # un-send). Without the gate, that drains a room being actively edited.
    test "a write inside the window is NOT idle, so a stale timer cannot drain it" do
      refute CrdtCheckpointTimer.idle?(
               %{last_activity_at: 9_999, idle_exit_ms: 1_000},
               10_000
             )
    end
  end

  describe "drain_delay/1 — backing off an unanswered drain (#1152)" do
    test "the first ask is at the plain idle window" do
      assert CrdtCheckpointTimer.drain_delay(%{idle_exit_ms: 1_000, drain_attempts: 0}) == 1_000
    end

    test "each unanswered drain lengthens the next ask" do
      assert CrdtCheckpointTimer.drain_delay(%{idle_exit_ms: 1_000, drain_attempts: 1}) == 2_000
      assert CrdtCheckpointTimer.drain_delay(%{idle_exit_ms: 1_000, drain_attempts: 3}) == 4_000
    end

    # An observer that can NEVER act (netsplit, wedged channel) must not hold a
    # fixed broadcast rate for the life of the room — but it must not go silent
    # either, or a later-reachable observer never gets asked again.
    test "the backoff is capped, so the re-ask never stops and never runs away" do
      assert CrdtCheckpointTimer.drain_delay(%{idle_exit_ms: 1_000, drain_attempts: 500}) == 8_000
    end
  end

  describe "jittered_drain_delay/1 — desynchronising the herd (#1152)" do
    # auto_exit fires on user behaviour, so exits spread themselves. Idle timers
    # are armed when the room STARTS, so a deploy or reconnect storm would arm
    # thousands identically and drain them in one instant — a synchronized
    # checkpoint storm, the 2026-07-09 pool-exhaustion shape.
    test "spreads repeated arms across a window instead of returning one value" do
      state = %{idle_exit_ms: 10_000, drain_attempts: 0}
      samples = for _ <- 1..200, do: CrdtCheckpointTimer.jittered_drain_delay(state)

      assert length(Enum.uniq(samples)) > 1, "no jitter — every room would drain in lockstep"
    end

    # idle_exit_ms is a FLOOR: the minimum quiet period before a room may be
    # taken away. Jitter that could shorten it would drain rooms that have not
    # actually been idle long enough.
    test "never fires EARLIER than the base delay, only later" do
      state = %{idle_exit_ms: 10_000, drain_attempts: 0}
      base = CrdtCheckpointTimer.drain_delay(state)

      for _ <- 1..200 do
        delay = CrdtCheckpointTimer.jittered_drain_delay(state)
        assert delay >= base
        assert delay <= base * 1.25
      end
    end

    test "jitter rides on top of the backoff, not instead of it" do
      backed_off = %{idle_exit_ms: 1_000, drain_attempts: 3}
      assert CrdtCheckpointTimer.jittered_drain_delay(backed_off) >= 4_000
    end
  end

  describe "compute_delay/2 — sustained editing stays debounced" do
    test "an edit within the settle window debounces by settle_ms (not eager)" do
      {delay, first_dirty_at} =
        CrdtCheckpointTimer.compute_delay(
          state(last_activity_at: 9_950, first_dirty_at: 9_950),
          10_000
        )

      assert delay == 1_000
      assert first_dirty_at == 9_950
    end

    test "the ceiling caps the delay so a continuously-edited note still flushes" do
      # first_dirty_at is 4_980ms ago -> only 20ms of ceiling budget remains.
      {delay, _} =
        CrdtCheckpointTimer.compute_delay(
          state(last_activity_at: 9_950, first_dirty_at: 5_020),
          10_000
        )

      assert delay == 20
    end
  end
end
