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

      assert [
               %Telemetry.Metrics.Counter{
                 tags: [:status, :cross_vault, :rerank, :filtered, :scope, :surface]
               } = requests,
               %Telemetry.Metrics.Counter{tags: [:filtered]} = empty
             ] = Enum.filter(metrics, &(&1.event_name == [:engram, :search, :request, :stop]))

      # An emitter without the #2697 labels still counts, under the defaults.
      assert requests.tag_values.(%{status: :ok, cross_vault: false, rerank: :off}) ==
               %{
                 status: :ok,
                 cross_vault: false,
                 rerank: :off,
                 filtered: false,
                 scope: :none,
                 surface: :internal
               }

      assert empty.name == [:engram, :prom_ex, :search, :empty, :total]
      assert empty.keep.(%{empty: true})
      refute empty.keep.(%{empty: false})
      refute empty.keep.(%{})
    end

    test "counts filter-only listings on [:engram, :search, :filter_page]" do
      metrics =
        PromExMetrics.of(SearchPlugin) |> List.wrap() |> Enum.flat_map(& &1.metrics)

      assert [%Telemetry.Metrics.Counter{tags: [:status, :surface, :empty]} = c] =
               Enum.filter(metrics, &(&1.event_name == [:engram, :search, :filter_page]))

      assert c.name == [:engram, :prom_ex, :search, :filter_page, :total]
    end

    test "times filter resolution on [:engram, :search, :filter_resolve], by scope" do
      metrics =
        PromExMetrics.of(SearchPlugin) |> List.wrap() |> Enum.flat_map(& &1.metrics)

      assert [%Telemetry.Metrics.Distribution{unit: :millisecond, tags: [:scope]} = d] =
               Enum.filter(metrics, &(&1.event_name == [:engram, :search, :filter_resolve]))

      assert d.name == [:engram, :prom_ex, :search, :filter_resolve, :milliseconds]
    end

    test "counts gate outcomes and times the wait on [:engram, :search, :gate]" do
      metrics =
        PromExMetrics.of(SearchPlugin) |> List.wrap() |> Enum.flat_map(& &1.metrics)

      gate = Enum.filter(metrics, &(&1.event_name == [:engram, :search, :gate]))

      assert [%Telemetry.Metrics.Counter{tags: [:outcome, :gate, :upstream]}] =
               Enum.filter(gate, &match?(%Telemetry.Metrics.Counter{}, &1))

      assert [%Telemetry.Metrics.Distribution{unit: :millisecond, tags: [:outcome, :gate]} = d] =
               Enum.filter(gate, &match?(%Telemetry.Metrics.Distribution{}, &1))

      # A pool-busy refusal never waited on a gate: counted, not timed.
      assert d.keep.(%{gate: :admission})
      refute d.keep.(%{gate: :pool})
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

    test "exports the name-index self-heal outcomes, by reason" do
      metrics =
        PromExMetrics.of(SearchPlugin) |> List.wrap() |> Enum.flat_map(& &1.metrics)

      for {name, event} <- [
            {:name_terms_skipped, [:engram, :name_terms, :skipped]},
            {:name_terms_deferred, [:engram, :name_terms, :deferred]},
            {:note_name_skipped, [:engram, :note_name, :skipped]},
            {:note_name_deferred, [:engram, :note_name, :deferred]}
          ] do
        assert [%Telemetry.Metrics.Sum{measurement: :count, tags: [:reason]} = m] =
                 Enum.filter(metrics, &(&1.event_name == event))

        assert m.name == [:engram, :prom_ex, :search, name, :total]
      end
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
