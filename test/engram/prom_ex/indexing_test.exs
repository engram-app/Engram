defmodule Engram.PromEx.IndexingTest do
  @moduledoc """
  Unit-tests the metric DEFINITIONS the plugin registers — that the repath
  `:stop` event maps to an outcome-tagged counter + points-sum, and that the
  link-rewrite `:failed` event (#648/#1231, Task 6) maps to a reason-tagged
  counter, all with the expected names. This guards the producer/consumer
  contract (event name, measurement key, cardinality) without standing up a
  full PromEx supervision tree.
  """
  use ExUnit.Case, async: true

  alias Engram.PromEx.Indexing

  @repath_stop_event [:engram, :indexing, :repath, :stop]
  @link_rewrite_failed_event [:engram, :links, :rewrite, :failed]

  test "event_metrics/1 maps the repath :stop event to outcome-tagged metrics" do
    built = Indexing.event_metrics(otp_app: :engram)
    metrics = built.metrics

    assert metrics != [], "plugin should register at least one metric"

    repath_metrics = Enum.filter(metrics, &(&1.event_name == @repath_stop_event))

    assert repath_metrics != [], "expected at least one repath metric"

    # Repath metrics are tagged ONLY by the bounded :outcome (cardinality
    # contract — never note_id/user_id/vault_id).
    assert Enum.all?(repath_metrics, &(&1.tags == [:outcome])),
           "repath metrics must be tagged by [:outcome] only, got: " <>
             inspect(Enum.map(repath_metrics, & &1.tags))

    names = Enum.map(repath_metrics, & &1.name)

    assert [:engram, :prom_ex, :indexing, :repath, :total] in names
    assert [:engram, :prom_ex, :indexing, :repath, :points, :total] in names

    counter = Enum.find(repath_metrics, &match?(%Telemetry.Metrics.Counter{}, &1))
    sum = Enum.find(repath_metrics, &match?(%Telemetry.Metrics.Sum{}, &1))

    assert counter, "expected a Counter for repath event total (events/sec by outcome)"
    assert sum, "expected a Sum for repath points total"

    # The points-sum reads the `count` measurement (points patched on :ok).
    assert sum.measurement == :count
  end

  test "event_metrics/1 maps the link-rewrite :failed event to a reason-tagged counter" do
    built = Indexing.event_metrics(otp_app: :engram)
    metrics = built.metrics

    link_rewrite_metrics = Enum.filter(metrics, &(&1.event_name == @link_rewrite_failed_event))

    assert [metric] = link_rewrite_metrics

    assert match?(%Telemetry.Metrics.Counter{}, metric)
    assert metric.name == [:engram, :prom_ex, :indexing, :link_rewrite, :failures, :total]

    # Cardinality contract: only the bounded :reason — never note/user/vault ids.
    assert metric.tags == [:reason]
  end
end
