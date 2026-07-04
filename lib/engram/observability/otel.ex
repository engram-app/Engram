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
    OpentelemetryBandit.setup()
    OpentelemetryPhoenix.setup(adapter: :bandit)
    OpentelemetryEcto.setup([:engram, :repo])
    :ok
  end
end
