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
