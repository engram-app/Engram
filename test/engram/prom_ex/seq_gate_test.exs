defmodule Engram.PromEx.SeqGateTest do
  use ExUnit.Case, async: true

  alias Engram.PromEx.SeqGate, as: Plugin
  alias Engram.Test.PromExMetrics

  defp metrics, do: PromExMetrics.of(Plugin) |> List.wrap() |> Enum.flat_map(& &1.metrics)

  test "is registered in the PromEx plugin list (else metrics never reach /metrics)" do
    assert Plugin in Engram.PromEx.plugins()
  end

  test "declares the busy counter, wait and hold histograms" do
    names = Enum.map(metrics(), & &1.name)
    assert [:engram, :prom_ex, :seq_gate, :acquire, :total] in names
    assert [:engram, :prom_ex, :seq_gate, :wait, :milliseconds] in names
    assert [:engram, :prom_ex, :seq_gate, :hold, :milliseconds] in names
  end

  test "polls the per-node queue gauges" do
    names =
      Plugin.polling_metrics(otp_app: :engram)
      |> List.wrap()
      |> Enum.flat_map(& &1.metrics)
      |> Enum.map(& &1.name)

    assert [:engram, :prom_ex, :seq_gate, :held] in names
    assert [:engram, :prom_ex, :seq_gate, :waiting] in names
  end

  test "no vault or user tags" do
    for m <- metrics(), tag <- m.tags, do: refute(tag in [:vault_id, :user_id])
  end
end
