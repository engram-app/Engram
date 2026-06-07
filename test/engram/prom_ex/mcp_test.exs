defmodule Engram.PromEx.McpTest do
  @moduledoc """
  Verifies the MCP PromEx plugin metric shape.

  The controller wiring is exercised by the existing
  `EngramWeb.McpControllerTest` suite — covering it here would need a
  full ConnCase + auth harness. Plugin-shape test below is the
  registration guard.
  """
  use ExUnit.Case, async: true

  alias Engram.PromEx.Mcp, as: McpPlugin
  alias PromEx.MetricTypes.Event

  describe "event_metrics/1" do
    test "returns Event struct(s) prefixed [:engram, :prom_ex, :mcp]" do
      events = McpPlugin.event_metrics(otp_app: :engram) |> List.wrap()
      assert Enum.all?(events, &match?(%Event{}, &1))
      metrics = Enum.flat_map(events, & &1.metrics)
      assert Enum.any?(metrics, fn m -> Enum.at(m.name, 2) == :mcp end)
    end

    test "declares distribution + counter on [:engram, :mcp, :tool, :stop]" do
      metrics = McpPlugin.event_metrics(otp_app: :engram) |> List.wrap() |> Enum.flat_map(& &1.metrics)
      target = [:engram, :mcp, :tool, :stop]
      assert Enum.any?(metrics, fn m -> match?(%Telemetry.Metrics.Distribution{}, m) and m.event_name == target end)
      assert Enum.any?(metrics, fn m -> match?(%Telemetry.Metrics.Counter{}, m) and m.event_name == target end)
    end

    test "declares a result_bytes distribution" do
      metrics = McpPlugin.event_metrics(otp_app: :engram) |> List.wrap() |> Enum.flat_map(& &1.metrics)

      assert Enum.any?(metrics, fn m ->
               match?(%Telemetry.Metrics.Distribution{}, m) and m.measurement == :result_bytes
             end)
    end

    test "no per-tenant tags" do
      metrics = McpPlugin.event_metrics(otp_app: :engram) |> List.wrap() |> Enum.flat_map(& &1.metrics)
      banned = [:user_id, :vault_id, :args, :tenant_id]

      for m <- metrics, tag <- m.tags do
        refute tag in banned, "Mcp metric #{inspect(m.name)} has banned tag #{inspect(tag)}"
      end
    end
  end
end
