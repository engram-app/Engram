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
