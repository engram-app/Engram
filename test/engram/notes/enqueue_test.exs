defmodule Engram.Notes.EnqueueTest do
  # T3-audit H3 — Oban.insert/1 returns {:ok, job} | {:error, changeset}.
  # Pre-fix, four sites in notes.ex pattern-matched neither and silently
  # discarded enqueue failures. Operator had no signal when queue was
  # saturated, when worker validation rejected args, or when Oban migration
  # drift returned changeset errors. This module wraps the call so failures
  # log + emit telemetry, while the success path is unaffected.
  use ExUnit.Case, async: true

  alias Engram.Notes.Enqueue

  describe "enqueue/3 (T3-audit H3)" do
    test "returns {:ok, job} from underlying insert on success" do
      stub = fn _changeset -> {:ok, %{id: 42}} end
      assert {:ok, %{id: 42}} = Enqueue.enqueue(:fake_changeset, "embed_note", stub)
    end

    test "logs error with worker label + reason on failure and returns {:error, _}" do
      stub = fn _changeset -> {:error, %{reason: :queue_saturated}} end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, %{reason: :queue_saturated}} =
                   Enqueue.enqueue(:fake_changeset, "embed_note", stub)
        end)

      assert log =~ "oban enqueue failed",
             "expected `oban enqueue failed` log line, got: #{log}"

      assert log =~ "worker=embed_note",
             "log must carry worker label for triage, got: #{log}"
    end

    test "emits [:engram, :notes, :enqueue, :failed] telemetry on failure" do
      :telemetry.attach(
        "enqueue-test-failed",
        [:engram, :notes, :enqueue, :failed],
        fn _name, measurements, metadata, _ ->
          send(self(), {:enqueue_failed, measurements, metadata})
        end,
        nil
      )

      try do
        stub = fn _ -> {:error, :nope} end
        assert {:error, :nope} = Enqueue.enqueue(:fake_changeset, "delete_note_index", stub)

        assert_received {:enqueue_failed, %{count: 1}, %{worker: "delete_note_index"}}
      after
        :telemetry.detach("enqueue-test-failed")
      end
    end

    test "emits no telemetry on success" do
      :telemetry.attach(
        "enqueue-test-success-no-emit",
        [:engram, :notes, :enqueue, :failed],
        fn _name, _, _, _ -> send(self(), :should_not_fire) end,
        nil
      )

      try do
        stub = fn _ -> {:ok, :job} end
        assert {:ok, :job} = Enqueue.enqueue(:fake_changeset, "any", stub)
        refute_received :should_not_fire
      after
        :telemetry.detach("enqueue-test-success-no-emit")
      end
    end
  end
end
