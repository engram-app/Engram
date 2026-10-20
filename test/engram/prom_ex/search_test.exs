defmodule Engram.PromEx.SearchTest do
  @moduledoc """
  Verifies the Search PromEx plugin metric shape.

  Wiring inside `Engram.Search.search/4` is covered by the existing
  search test suite (it needs the full DB + Qdrant + Voyage Bypass
  harness). The plugin-shape test below is what guards registration.
  """
  use ExUnit.Case, async: true

  alias Engram.PromEx.Search, as: SearchPlugin
  alias Engram.Test.PromExMetrics
  alias PromEx.MetricTypes.Event

  describe "event_metrics/1" do
    test "returns Event struct(s) prefixed [:engram, :prom_ex, :search]" do
      events = PromExMetrics.of(SearchPlugin) |> List.wrap()
      assert Enum.all?(events, &match?(%Event{}, &1))
      metrics = Enum.flat_map(events, & &1.metrics)
      assert Enum.any?(metrics, fn m -> Enum.at(m.name, 2) == :search end)
    end

    # Duration and result-count histograms had no reader; search latency is
    # in Tempo. The request counter stays.
    test "declares only a counter on [:engram, :search, :request, :stop]" do
      metrics =
        PromExMetrics.of(SearchPlugin) |> List.wrap() |> Enum.flat_map(& &1.metrics)

      assert [%Telemetry.Metrics.Counter{tags: [:status, :cross_vault, :rerank]}] =
               Enum.filter(metrics, &(&1.event_name == [:engram, :search, :request, :stop]))
    end

    test "sums dropped hits from [:engram, :search, :hit_dropped]" do
      metrics =
        PromExMetrics.of(SearchPlugin) |> List.wrap() |> Enum.flat_map(& &1.metrics)

      assert Enum.any?(metrics, fn m ->
               match?(%Telemetry.Metrics.Sum{}, m) and
                 m.event_name == [:engram, :search, :hit_dropped] and m.measurement == :count and
                 m.tags == [:reason]
             end)
    end

    test "no per-tenant tags" do
      metrics =
        PromExMetrics.of(SearchPlugin) |> List.wrap() |> Enum.flat_map(& &1.metrics)

      banned = [:user_id, :vault_id, :query, :tenant_id]

      for m <- metrics, tag <- m.tags do
        refute tag in banned, "Search metric #{inspect(m.name)} has banned tag #{inspect(tag)}"
      end
    end
  end
end
