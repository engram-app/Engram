defmodule Engram.Observability.Otel do
  @moduledoc """
  OpenTelemetry tracing wiring for Engram. Off unless
  `OTEL_EXPORTER_OTLP_ENDPOINT` is set, so dev/test/self-host emit
  nothing. `attach_handlers/0` installs the Phoenix + Ecto telemetry
  instrumentation; `span_context/0` exposes the active trace/span id
  for log correlation.
  """

  require Logger

  @doc "True when the OTLP exporter endpoint is configured."
  @spec enabled?() :: boolean()
  def enabled? do
    case System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") do
      nil -> false
      "" -> false
      _ -> true
    end
  end

  @doc """
  Parse a trace sample ratio (0.0..1.0) from an env string, clamping
  out-of-range values and falling back to the default for nil/garbage.
  """
  @spec sample_ratio(String.t() | nil, float()) :: float()
  def sample_ratio(nil, default), do: default

  def sample_ratio(value, default) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {n, ""} -> n |> max(0.0) |> min(1.0)
      _ -> default
    end
  end

  @doc """
  Attach the Phoenix + Ecto + Bandit telemetry handlers that turn our
  existing `:telemetry` events into OpenTelemetry spans. Call once at
  boot, gated on `enabled?/0` (see `Engram.Application.start/2`).
  """
  @spec attach_handlers() :: :ok
  def attach_handlers do
    # setup/0,1 return :ok | {:error, :already_exists}; bind to satisfy the
    # :unmatched_returns dialyzer flag. Re-attaching is harmless (idempotent).
    _ = OpentelemetryBandit.setup()
    _ = OpentelemetryPhoenix.setup(adapter: :bandit)
    _ = OpentelemetryEcto.setup([:engram, :repo])
    :ok
  end

  @doc """
  The active span's `{hex_trace_id, hex_span_id}`, or nil when no span
  is current. Used to stamp trace ids onto log metadata.
  """
  @spec span_context() :: {String.t(), String.t()} | nil
  def span_context do
    case OpenTelemetry.Tracer.current_span_ctx() do
      :undefined ->
        nil

      span_ctx ->
        trace_id = :otel_span.hex_trace_id(span_ctx)
        span_id = :otel_span.hex_span_id(span_ctx)

        # An all-zero trace id means an invalid/empty context.
        if trace_id == String.duplicate("0", 32) do
          nil
        else
          {to_string(trace_id), to_string(span_id)}
        end
    end
  end
end
