defmodule Engram.PromEx.SearchTest do
  @moduledoc """
  Verifies the Search PromEx plugin metric shape.

  Wiring inside `Engram.Search.search/4` is covered by the existing
  search test suite (it needs the full DB + Qdrant + Voyage Bypass
  harness). The plugin-shape test below is what guards registration.
  """
  use ExUnit.Case, async: true

  alias Engram.PromEx.Search, as: SearchPlugin
  alias PromEx.MetricTypes.Event

  describe "event_metrics/1" do
    test "returns Event struct(s) prefixed [:engram, :prom_ex, :search]" do
      events = SearchPlugin.event_metrics(otp_app: :engram) |> List.wrap()
      assert Enum.all?(events, &match?(%Event{}, &1))
      metrics = Enum.flat_map(events, & &1.metrics)
      assert Enum.any?(metrics, fn m -> Enum.at(m.name, 2) == :search end)
    end

    test "declares distribution + counter on [:engram, :search, :request, :stop]" do
      metrics = SearchPlugin.event_metrics(otp_app: :engram) |> List.wrap() |> Enum.flat_map(& &1.metrics)
      target = [:engram, :search, :request, :stop]
      assert Enum.any?(metrics, fn m -> match?(%Telemetry.Metrics.Distribution{}, m) and m.event_name == target end)
      assert Enum.any?(metrics, fn m -> match?(%Telemetry.Metrics.Counter{}, m) and m.event_name == target end)
    end

    test "declares a result_count distribution" do
      metrics = SearchPlugin.event_metrics(otp_app: :engram) |> List.wrap() |> Enum.flat_map(& &1.metrics)

      assert Enum.any?(metrics, fn m ->
               match?(%Telemetry.Metrics.Distribution{}, m) and m.measurement == :result_count
             end),
             "Must expose result count as its own distribution measurement"
    end

    test "no per-tenant tags" do
      metrics = SearchPlugin.event_metrics(otp_app: :engram) |> List.wrap() |> Enum.flat_map(& &1.metrics)
      banned = [:user_id, :vault_id, :query, :tenant_id]

      for m <- metrics, tag <- m.tags do
        refute tag in banned, "Search metric #{inspect(m.name)} has banned tag #{inspect(tag)}"
      end
    end
  end
end
