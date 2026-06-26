defmodule Engram.PromEx.IndexingTest do
  @moduledoc """
  Unit-tests the metric DEFINITIONS the plugin registers — that the repath
  `:stop` event maps to an outcome-tagged counter + points-sum with the
  expected names. This guards the producer/consumer contract (event name,
  measurement key, cardinality) without standing up a full PromEx supervision
  tree.
  """
  use ExUnit.Case, async: true

  alias Engram.PromEx.Indexing

  @repath_stop_event [:engram, :indexing, :repath, :stop]

  test "event_metrics/1 maps the repath :stop event to outcome-tagged metrics" do
    built = Indexing.event_metrics(otp_app: :engram)
    metrics = built.metrics

    assert metrics != [], "plugin should register at least one metric"

    # Every metric subscribes to the single repath :stop event...
    assert Enum.all?(metrics, &(&1.event_name == @repath_stop_event)),
           "all repath metrics must subscribe to #{inspect(@repath_stop_event)}"

    # ...and is tagged ONLY by the bounded :outcome (cardinality contract —
    # never note_id/user_id/vault_id).
    assert Enum.all?(metrics, &(&1.tags == [:outcome])),
           "repath metrics must be tagged by [:outcome] only, got: " <>
             inspect(Enum.map(metrics, & &1.tags))

    names = Enum.map(metrics, & &1.name)

    assert [:engram, :prom_ex, :indexing, :repath, :total] in names
    assert [:engram, :prom_ex, :indexing, :repath, :points, :total] in names

    counter = Enum.find(metrics, &match?(%Telemetry.Metrics.Counter{}, &1))
    sum = Enum.find(metrics, &match?(%Telemetry.Metrics.Sum{}, &1))

    assert counter, "expected a Counter for repath event total (events/sec by outcome)"
    assert sum, "expected a Sum for repath points total"

    # The points-sum reads the `count` measurement (points patched on :ok).
    assert sum.measurement == :count
  end
end
