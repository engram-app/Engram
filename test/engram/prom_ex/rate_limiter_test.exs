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

  test "is registered in the PromEx plugin list (else metrics never reach /metrics)" do
    assert Plugin in Engram.PromEx.plugins()
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

  describe "polling_metrics/1 — cluster status (works clustered + standalone)" do
    alias PromEx.MetricTypes.Polling

    defp polling do
      Plugin.polling_metrics(otp_app: :engram) |> List.wrap()
    end

    test "returns a Polling group with peers + distributed last_value gauges" do
      groups = polling()
      assert groups != []
      assert Enum.all?(groups, &match?(%Polling{}, &1))

      metrics = Enum.flat_map(groups, & &1.metrics)
      names = Enum.map(metrics, & &1.name)

      assert [:engram, :prom_ex, :rate_limiter, :cluster, :peers] in names
      assert [:engram, :prom_ex, :rate_limiter, :cluster, :distributed] in names
      assert Enum.all?(metrics, &match?(%Telemetry.Metrics.LastValue{}, &1))
    end

    test "execute_cluster_metrics/0 emits peers + distributed (0/0 when standalone :ets)" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        {__MODULE__, ref},
        [:engram, :rate_limiter, :cluster],
        fn _name, meas, _meta, _ -> send(test_pid, {:cluster, ref, meas}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

      # In the test VM there are no connected peers and the backend is :ets,
      # so this is the standalone/non-clustered reading: peers 0, distributed 0.
      Plugin.execute_cluster_metrics()
      assert_receive {:cluster, ^ref, %{peers: 0, distributed: 0}}, 1000
    end
  end
end
