defmodule Engram.PromEx.WebSocketTest do
  @moduledoc """
  Verifies the WebSocket PromEx plugin puts the socket signals on `/metrics`.
  Emission is covered by `Engram.Telemetry.WebSocketPollerTest` and
  `EngramWeb.MeteredSerializerTest`.
  """
  use ExUnit.Case, async: true

  alias Engram.PromEx.WebSocket, as: Plugin

  defp metrics do
    (List.wrap(Plugin.event_metrics(otp_app: :engram)) ++
       List.wrap(Plugin.polling_metrics(otp_app: :engram)))
    |> Enum.flat_map(& &1.metrics)
  end

  defp find(name), do: Enum.find(metrics(), &(&1.name == name))

  test "is registered in the PromEx plugin list (else metrics never reach /metrics)" do
    assert Plugin in Engram.PromEx.plugins()
  end

  test "frame rate and bytes are sums over [:engram, :websocket, :frame]" do
    for {name, measurement} <- [
          {[:engram, :prom_ex, :websocket, :frames, :total], :count},
          {[:engram, :prom_ex, :websocket, :frame_bytes, :total], :bytes}
        ] do
      m = find(name)
      assert %Telemetry.Metrics.Sum{} = m, "missing #{inspect(name)}"
      assert m.event_name == [:engram, :websocket, :frame]
      assert m.measurement == measurement
      assert m.tags == [:direction, :kind, :topic_prefix]
    end
  end

  test "live connections and channels are polled gauges" do
    assert %Telemetry.Metrics.LastValue{tags: [:socket]} =
             find([:engram, :prom_ex, :websocket, :connections])

    assert %Telemetry.Metrics.LastValue{tags: [:topic_prefix]} =
             find([:engram, :prom_ex, :websocket, :channels])

    assert %Telemetry.Metrics.Distribution{tags: [:topic_prefix]} =
             find([:engram, :prom_ex, :websocket, :channel_memory, :bytes])
  end

  test "polls every 30s by default (cadence contract)" do
    [polling] = List.wrap(Plugin.polling_metrics(otp_app: :engram))

    assert polling.poll_rate == :timer.seconds(30),
           "WS gauge cadence is a contract: 30s balances spike-visibility against the O(processes) scan"
  end

  test "no per-tenant / unbounded tags" do
    banned = [:user_id, :vault_id, :topic, :event, :ip]

    for m <- metrics(), tag <- m.tags do
      refute tag in banned, "metric #{inspect(m.name)} has banned tag #{inspect(tag)}"
    end
  end
end
