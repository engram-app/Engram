defmodule Engram.Telemetry.ObanDiscardHandlerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Engram.Telemetry.ObanDiscardHandler

  setup do
    ObanDiscardHandler.attach()
    # Capture the test pid at attach time — `self()` inside on_exit is the
    # on_exit process, so closing over the actual test pid is the only way
    # detach hits the right handler key.
    test_pid = self()
    handler_key = {__MODULE__, test_pid}

    :telemetry.attach(
      handler_key,
      [:engram, :oban, :discarded],
      fn _name, measurements, metadata, _config ->
        send(test_pid, {:discarded_emitted, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_key) end)
    :ok
  end

  describe "handle_event/4 — timeouts" do
    # A timeout on a NON-final attempt used to be silent: the discard clause
    # only fires once `max_attempts` is burned, which on `embed` (5 attempts,
    # exponential backoff) is hours after the queue has already stopped. The
    # 2026-08-28 prod stall was exactly that hole — both queues fully occupied,
    # zero log lines anywhere. See #1496.
    test "logs a warning and emits [:engram, :oban, :timeout] on the FIRST attempt" do
      test_pid = self()
      key = {__MODULE__, :timeout, test_pid}

      :telemetry.attach(
        key,
        [:engram, :oban, :timeout],
        fn _name, measurements, metadata, _config ->
          send(test_pid, {:timeout_emitted, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(key) end)

      metadata = %{
        # NOT :discarded — attempt 1 of 5, which is the case that was silent.
        state: :failure,
        worker: "Engram.Workers.EmbedNote",
        queue: :embed,
        job: %{id: 42, args: %{"note_id" => 7}, attempt: 1, max_attempts: 5},
        kind: :exit,
        reason: %Oban.TimeoutError{
          message: "Engram.Workers.EmbedNote timed out after 600000ms",
          reason: :timeout
        }
      }

      logs =
        capture_log(fn ->
          :telemetry.execute(
            [:oban, :job, :exception],
            %{duration: System.convert_time_unit(600_000, :millisecond, :native)},
            metadata
          )

          Process.sleep(10)
        end)

      assert logs =~ "Oban job timed out"
      assert logs =~ "Engram.Workers.EmbedNote"
      assert logs =~ "attempt=1/5"
      assert logs =~ "ran_ms=600000"

      assert_received {:timeout_emitted, %{count: 1}, m}
      assert m.worker == "Engram.Workers.EmbedNote"
      assert m.queue == :embed
    end

    # Clause order matters: a timeout that also exhausts max_attempts must read
    # as the terminal fact, not as one more timeout among five.
    test "a timeout on the FINAL attempt logs the discard, not the timeout" do
      metadata = %{
        state: :discarded,
        worker: "Engram.Workers.EmbedNote",
        queue: :embed,
        job: %{id: 43, args: %{}, attempt: 5, max_attempts: 5},
        kind: :exit,
        reason: %Oban.TimeoutError{message: "timed out after 600000ms", reason: :timeout}
      }

      logs =
        capture_log(fn ->
          :telemetry.execute([:oban, :job, :exception], %{duration: 1_000}, metadata)
          Process.sleep(10)
        end)

      assert logs =~ "Oban job discarded"
      refute logs =~ "Oban job timed out"
    end
  end

  describe "handle_event/4 — discarded jobs" do
    test "logs a warning and re-emits [:engram, :oban, :discarded] when state is :discarded" do
      measurements = %{duration: 1_000, queue_time: 0}

      metadata = %{
        state: :discarded,
        worker: "Engram.Workers.EmbedNote",
        queue: :embed,
        job: %{id: 42, args: %{"note_id" => 7}, attempt: 5, max_attempts: 5},
        kind: :error,
        reason: %RuntimeError{message: "boom"}
      }

      logs =
        capture_log(fn ->
          :telemetry.execute([:oban, :job, :exception], measurements, metadata)
          # Give the handler a moment to run synchronously through telemetry.
          Process.sleep(10)
        end)

      assert logs =~ "Oban job discarded"
      assert logs =~ "Engram.Workers.EmbedNote"

      # The bounded error class (exception module) IS surfaced so an operator
      # can see the root cause — "job discarded" with no cause is useless in an
      # incident. error_kind/1 yields only the struct module, never the
      # secret-bearing fields: "boom" (the :message) must stay out.
      assert logs =~ "error_kind="
      assert logs =~ "RuntimeError"
      refute logs =~ "boom"

      assert_received {:discarded_emitted, %{count: 1}, m}
      assert m.worker == "Engram.Workers.EmbedNote"
      assert m.queue == :embed
      assert m.error_kind == RuntimeError
    end

    test "surfaces a bounded error_kind without leaking a secret in the reason" do
      secret = "REDIS-URL-PASSWORD-do-not-leak"
      measurements = %{duration: 1_000, queue_time: 0}

      metadata = %{
        state: :discarded,
        worker: "Engram.Workers.EmbedNote",
        queue: :embed,
        job: %{id: 99, args: %{}, attempt: 3, max_attempts: 3},
        kind: :error,
        # A connection error term that carries a secret in its payload, as a
        # Redix/Req error would. error_kind/1 keeps only the leading atom.
        reason: {:connection_error, secret}
      }

      logs =
        capture_log(fn ->
          :telemetry.execute([:oban, :job, :exception], measurements, metadata)
          Process.sleep(10)
        end)

      assert logs =~ "error_kind=connection_error"
      refute logs =~ secret
    end

    test "does NOT log or re-emit for non-discard exceptions (state :failure)" do
      measurements = %{duration: 1_000, queue_time: 0}

      metadata = %{
        state: :failure,
        worker: "Engram.Workers.EmbedNote",
        queue: :embed,
        job: %{id: 42, args: %{}, attempt: 2, max_attempts: 5},
        kind: :error,
        reason: %RuntimeError{message: "transient"}
      }

      logs =
        capture_log(fn ->
          :telemetry.execute([:oban, :job, :exception], measurements, metadata)
          Process.sleep(10)
        end)

      refute logs =~ "Oban job discarded"
      refute_received {:discarded_emitted, _, _}
    end

    test "attach/0 is idempotent (no duplicate handlers on second call)" do
      :ok = ObanDiscardHandler.attach()
      :ok = ObanDiscardHandler.attach()

      measurements = %{duration: 1_000}

      metadata = %{
        state: :discarded,
        worker: "X",
        queue: :default,
        job: %{id: 1, args: %{}, attempt: 1, max_attempts: 1},
        kind: :error,
        reason: :boom
      }

      capture_log(fn ->
        :telemetry.execute([:oban, :job, :exception], measurements, metadata)
        Process.sleep(10)
      end)

      # Re-emission probe should receive exactly one message, not two.
      assert_received {:discarded_emitted, _, _}
      refute_received {:discarded_emitted, _, _}
    end
  end
end
