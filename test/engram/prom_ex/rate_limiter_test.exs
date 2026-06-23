defmodule Engram.PromEx.RateLimiterTest do
  @moduledoc """
  Verifies the RateLimiter PromEx plugin declares the expected counters and
  obeys the cardinality contract. The emission itself is covered by
  `EngramWeb.RateLimiterTest` and `EngramWeb.RateLimiter.DistributedETSTest`.
  """
  use ExUnit.Case, async: true

  alias Engram.PromEx.RateLimiter, as: Plugin
  alias PromEx.MetricTypes.Event

  defp metrics do
    Plugin.event_metrics(otp_app: :engram) |> List.wrap() |> Enum.flat_map(& &1.metrics)
  end

  test "event_metrics/1 returns Event struct(s)" do
    events = Plugin.event_metrics(otp_app: :engram) |> List.wrap()
    assert events != []
    assert Enum.all?(events, &match?(%Event{}, &1))
  end

  test "declares a counter on [:engram, :rate_limiter, :hit] tagged [:purpose, :result]" do
    target = [:engram, :rate_limiter, :hit]

    assert Enum.any?(metrics(), fn m ->
             match?(%Telemetry.Metrics.Counter{}, m) and
               m.event_name == target and
               m.tags == [:purpose, :result]
           end)
  end

  test "declares a counter on [:engram, :rate_limiter, :remote_inc] tagged [:result]" do
    target = [:engram, :rate_limiter, :remote_inc]

    assert Enum.any?(metrics(), fn m ->
             match?(%Telemetry.Metrics.Counter{}, m) and
               m.event_name == target and
               m.tags == [:result]
           end)
  end

  test "no per-tenant / unbounded tags" do
    banned = [:user_id, :vault_id, :key, :ip, :path, :request_path, :tenant_id]

    for m <- metrics(), tag <- m.tags do
      refute tag in banned, "metric #{inspect(m.name)} has banned tag #{inspect(tag)}"
    end
  end
end
