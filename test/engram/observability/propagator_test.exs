defmodule Engram.Observability.PropagatorTest do
  use ExUnit.Case, async: false

  test "an inbound traceparent becomes the parent of a locally started span" do
    trace_hex = "33333333333333333333333333333333"
    parent_hex = "4444444444444444"
    # extract/1 attaches the remote context and returns the PRIOR context as
    # the detach token. Do NOT re-attach the return value, that would
    # discard the remote parent (see Task 1 finding).
    token =
      :otel_propagator_text_map.extract([{"traceparent", "00-#{trace_hex}-#{parent_hex}-01"}])

    try do
      current = OpenTelemetry.Tracer.current_span_ctx()
      hex_trace = current |> :otel_span.hex_trace_id() |> to_string()
      assert hex_trace == trace_hex
    after
      OpenTelemetry.Ctx.detach(token)
    end
  end
end
