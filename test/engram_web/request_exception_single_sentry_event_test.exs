defmodule EngramWeb.RequestExceptionSingleSentryEventTest do
  @moduledoc """
  One request crash must produce exactly one Sentry event.

  Two paths see a crashing request: `Sentry.PlugCapture` (endpoint.ex)
  captures it, and `EngramWeb.RequestExceptionLogger` logs it at error with
  `crash_reason`, which Sentry's LoggerHandler would capture too. The second
  is excluded only because that line carries `domain: [:bandit]` and the
  handler's `capture_excluded_domains` defaults to `[:cowboy, :bandit]`
  (sentry 13.5.1; our handler config does not override it). The two events
  would not dedupe: the logger's exception is the sanitized one, a different
  hash from PlugCapture's raw exception.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Engram.Logger.Metadata

  require Logger

  @exception %RuntimeError{message: "boom"}
  @stacktrace [{__MODULE__, :crash, 0, [file: ~c"crash.ex", line: 1]}]

  setup do
    Sentry.Test.setup_sentry()
  end

  # The handler logs and returns; Sentry's LoggerHandler sends asynchronously.
  defp logged(fun) do
    capture_log([level: :error], fn ->
      fun.()
      Process.sleep(200)
    end)
  end

  test "PlugCapture reports a request crash once; the logger line adds nothing" do
    logged(fn ->
      EngramWeb.RequestExceptionLogger.handle_event(
        [:bandit, :request, :exception],
        %{},
        %{kind: :exit, exception: @exception, stacktrace: @stacktrace},
        nil
      )
    end)

    assert Sentry.Test.pop_sentry_reports() == []

    :ok =
      Sentry.PlugCapture.__capture_exception__(
        @exception,
        @stacktrace,
        {Sentry.PlugCapture, :default_scrubber, []}
      )

    assert [_one] = Sentry.Test.pop_sentry_reports()
  end

  # Control: without this, a LoggerHandler that was never attached in test
  # would pass the test above. The same crash line minus the bandit domain IS
  # captured, so the exclusion is what keeps it to one event. Same metadata
  # shape as RequestExceptionLogger's line, minus `domain`.
  test "control: the same crash line without the bandit domain is captured" do
    logged(fn ->
      Logger.error(
        "boom",
        Metadata.with_category(:error, :http, crash_reason: {@exception, @stacktrace})
      )
    end)

    assert [_] = Sentry.Test.pop_sentry_reports()
  end
end
