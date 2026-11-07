defmodule Engram.PromEx.IndexingTest do
  @moduledoc """
  Unit-tests the metric DEFINITIONS the plugin registers: that the
  link-rewrite `:failed` event (#648/#1231, Task 6) maps to a reason-tagged
  counter, all with the expected names. This guards the producer/consumer
  contract (event name, measurement key, cardinality) without standing up a
  full PromEx supervision tree.
  """
  use ExUnit.Case, async: true

  alias Engram.PromEx.Indexing
  alias Engram.Test.PromExMetrics

  @link_rewrite_failed_event [:engram, :links, :rewrite, :failed]

  test "no repath metric is registered (R3a: a rename makes no Qdrant write)" do
    refute Enum.any?(PromExMetrics.of(Indexing).metrics, &(:repath in &1.name))
  end

  test "event_metrics/1 maps the link-rewrite :failed event to a reason-tagged counter" do
    built = PromExMetrics.of(Indexing)
    metrics = built.metrics

    link_rewrite_metrics = Enum.filter(metrics, &(&1.event_name == @link_rewrite_failed_event))

    assert [metric] = link_rewrite_metrics

    assert match?(%Telemetry.Metrics.Counter{}, metric)
    assert metric.name == [:engram, :prom_ex, :indexing, :link_rewrite, :failures, :total]

    # Cardinality contract: only the bounded :reason — never note/user/vault ids.
    assert metric.tags == [:reason]
  end

  # Version rebuilds are never charged to a user's cap, so this sum is the only
  # record of that spend. It must read the event EmbedNote emits.
  test "event_metrics/1 sums maintenance embed tokens from EmbedNote's event" do
    built = PromExMetrics.of(Indexing)

    assert [metric] =
             Enum.filter(built.metrics, &(&1.event_name == [:engram, :embed, :maintenance]))

    assert match?(%Telemetry.Metrics.Sum{}, metric)
    assert metric.name == [:engram, :prom_ex, :indexing, :maintenance_embed_tokens, :total]
    assert metric.measurement == :tokens
    assert metric.tags == []
  end

  # Skipped cache writes are vectors a retry pays for again: exported, by a
  # closed :reason only.
  test "event_metrics/1 sums skipped vector cache rows by reason" do
    built = Indexing.event_metrics(otp_app: :engram)

    assert [metric] =
             Enum.filter(built.metrics, &(&1.event_name == [:engram, :vector_cache, :skipped]))

    assert match?(%Telemetry.Metrics.Sum{}, metric)
    assert metric.name == [:engram, :prom_ex, :indexing, :vector_cache, :skipped_rows, :total]
    assert metric.measurement == :rows
    assert metric.tags == [:reason]
  end
end
