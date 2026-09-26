defmodule Engram.Observability.SpanExceptionEventsTest do
  @moduledoc """
  Bandit and Phoenix call `record_exception/3` on a crashing request, which adds
  an event with `exception.message` (a MatchError inspects its whole term) and
  `exception.stacktrace` (top-frame arguments). Neither is a span attribute, so
  `SpanScrubber.on_start` cannot reach them; the SDK event limit drops them.
  """
  use ExUnit.Case, async: false

  require OpenTelemetry.Tracer, as: Tracer
  require Record
  @fields Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  Record.defrecordp(:span, @fields)

  setup do
    :application.set_env(:opentelemetry, :traces_exporter, {:otel_exporter_pid, self()})
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    :ok
  end

  test "a recorded exception exports no message or stacktrace" do
    {e, st} =
      try do
        {:ok, _} = Function.identity({:error, %{"path" => "Medical/canary-5d2b.md"}})
      rescue
        e -> {e, __STACKTRACE__}
      end

    Tracer.with_span "GET", %{kind: :server} do
      Tracer.record_exception(e, st)
    end

    assert_receive {:span, record}, 2_000
    refute inspect(span(record, :events)) =~ "canary-5d2b"
  end
end
