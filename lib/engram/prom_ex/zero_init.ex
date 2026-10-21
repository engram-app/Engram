defmodule Engram.PromEx.ZeroInit do
  @moduledoc """
  Emits a 0 for every alerted counter series once at boot, right after
  `Engram.PromEx` attaches its handlers.

  A counter series only exists from its first event, and Prometheus'
  `increase()` needs a sample before the step: a series whose first sample
  is already 1 reads as no increase, so an isolated failure after a deploy
  never pages (engram-infra #1525 review). Seeding 0 makes every alerted
  series exist from boot.

  A series is the FULL label set, so each entry names the exact label values
  an emit site sends. Add one here when an alert selects a new label value.

  Same module as main's (961f73186, the crypto and payload-reconcile series):
  when the branches meet, the list is the union of both.
  """

  @search_hits [:engram, :search, :hits]
  @search_text_missing [:engram, :search, :text_missing]
  @search_hit_dropped [:engram, :search, :hit_dropped]

  # The `hit_dropped` reasons the undecryptable-text alert selects
  # (`Engram.Search`): a key or ciphertext fault, never an expected orphan.
  @undecryptable [:text_undecryptable, :note_undecryptable, :payload_undecryptable]

  @doc false
  def child_spec(_arg), do: %{Task.child_spec(&run/0) | id: __MODULE__}

  @doc "`{event, measurements, metadata}` for each seeded series."
  def series do
    # `sum` metrics over `count`: a 0 adds nothing to the total.
    [{@search_hits, %{count: 0}, %{}}, {@search_text_missing, %{count: 0}, %{}}] ++
      for reason <- @undecryptable,
          do: {@search_hit_dropped, %{count: 0}, %{reason: reason}}
  end

  @doc "The same series as Prometheus names them: `{metric, %{label => value}}`."
  def prometheus_series do
    for {event, _measurements, meta} <- series() do
      metric =
        case event do
          @search_hits -> "engram_prom_ex_search_hits_total"
          @search_text_missing -> "engram_prom_ex_search_text_missing_total"
          @search_hit_dropped -> "engram_prom_ex_search_hits_dropped_total"
        end

      {metric, Map.new(meta, fn {k, v} -> {k, to_string(v)} end)}
    end
  end

  @doc "Emits each series' 0."
  def run do
    for {event, measurements, meta} <- series(), do: :telemetry.execute(event, measurements, meta)
    :ok
  end
end
