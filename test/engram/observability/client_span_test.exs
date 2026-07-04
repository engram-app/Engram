defmodule Engram.Observability.ClientSpanTest do
  use ExUnit.Case, async: false

  require Record
  # Pull in the SDK span record so we can read exported fields.
  @fields Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  Record.defrecordp(:span, @fields)

  alias Engram.Observability.ClientSpan

  setup do
    # Route exported spans to this process via the in-memory (pid) exporter.
    :application.set_env(:opentelemetry, :traces_exporter, {:otel_exporter_pid, self()})
    # Force recording regardless of ambient sampler.
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    :ok
  end

  test "records a child of the remote parent with client wall-clock times" do
    # A known sampled remote parent: trace T, parent span P, flags 01.
    trace_hex = "11111111111111111111111111111111"
    parent_hex = "2222222222222222"
    traceparent = "00-#{trace_hex}-#{parent_hex}-01"

    start_us = 1_783_200_000_000_000
    end_us = start_us + 12_000

    assert :ok =
             ClientSpan.record(%{
               traceparent: traceparent,
               name: "browser.live_sync.render",
               start_us: start_us,
               end_us: end_us,
               attributes: %{"engram.surface" => "web"}
             })

    assert_receive {:span, span_record}, 2_000
    s = span(span_record)

    # Same trace, parented to P.
    assert Integer.to_string(s[:trace_id], 16) |> String.downcase() |> String.pad_leading(32, "0") ==
             trace_hex

    assert Integer.to_string(s[:parent_span_id], 16)
           |> String.downcase()
           |> String.pad_leading(16, "0") ==
             parent_hex

    # Client wall-clock times survive as unix nanoseconds (the unit we are pinning).
    assert :opentelemetry.convert_timestamp(s[:start_time], :microsecond) == start_us
    assert :opentelemetry.convert_timestamp(s[:end_time], :microsecond) == end_us
  end
end
