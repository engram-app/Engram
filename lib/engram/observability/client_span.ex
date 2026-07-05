defmodule Engram.Observability.ClientSpan do
  @moduledoc """
  Materializes a client-reported span (a "beacon") as a child of a remote
  W3C `traceparent`, using the app's own tracer + exporter. Clients own the
  trace id and the parent pointer; the child span id is generated here. This
  is how an Obsidian push or a browser render becomes a visible span in the
  same Tempo trace without the client shipping OTLP.

  Timestamps are client wall-clock microseconds. `opentelemetry:timestamp/0`
  (the type `start_time`/`end_span/2` expect) is documented as "a
  monotonically increasing time... in the native time unit", i.e. it is
  `erlang:monotonic_time/0`, NOT unix-epoch nanoseconds. The exporter later
  converts it back to a wall-clock time via
  `erlang:convert_time_unit(Timestamp + erlang:time_offset(), native, Unit)`
  (`opentelemetry:convert_timestamp/2`). To make an explicit span carry a
  client-supplied wall-clock time we have to invert that formula: convert the
  target wall-clock value into `:native` units and subtract the current
  `time_offset()`, so that re-applying the offset on export reproduces the
  client's wall-clock instant exactly. `client_span_test` pins this
  round-trip against the in-memory exporter.
  """
  require OpenTelemetry.Tracer, as: Tracer
  require OpenTelemetry.Span, as: Span

  @spec record(%{
          :traceparent => String.t(),
          :name => String.t(),
          :start_us => integer(),
          :end_us => integer(),
          optional(any()) => any()
        }) :: :ok | {:error, Exception.t()}
  def record(%{traceparent: traceparent, name: name, start_us: start_us, end_us: end_us} = entry) do
    # `:otel_propagator_text_map.extract/1` already attaches the extracted
    # context as a side effect and hands back the *previous* context as an
    # opaque token (see otel_ctx.erl: "the token is actually the context map
    # itself"). Attaching that token again here would immediately clobber the
    # just-extracted remote parent back to the pre-call (empty) context,
    # silently turning every child span into a fresh root trace. Treat the
    # return value purely as the detach token.
    token = :otel_propagator_text_map.extract([{"traceparent", traceparent}])

    try do
      start_native = wall_clock_us_to_native(start_us)
      end_native = wall_clock_us_to_native(end_us)

      attributes =
        entry
        |> Map.get(:attributes, %{})
        |> Map.put("telemetry.source", "client")

      span = Tracer.start_span(name, %{start_time: start_native, attributes: attributes})
      # end_span/2 returns the ended span ctx; we don't need it (the exporter
      # ships on end). Bind it so dialyzer doesn't flag an unmatched return.
      _ended = Span.end_span(span, end_native)
      :ok
    after
      OpenTelemetry.Ctx.detach(token)
    end
  rescue
    e -> {:error, e}
  end

  # Inverse of `opentelemetry:convert_timestamp/2`: given a wall-clock unix
  # microsecond timestamp, produce the `:native`-unit value that, once the
  # SDK re-adds `:erlang.time_offset/0` and converts back on export, yields
  # that same wall-clock microsecond value.
  defp wall_clock_us_to_native(wall_clock_us) do
    System.convert_time_unit(wall_clock_us, :microsecond, :native) - :erlang.time_offset()
  end
end
