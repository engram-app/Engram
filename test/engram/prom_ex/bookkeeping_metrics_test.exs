defmodule Engram.PromEx.BookkeepingMetricsTest do
  @moduledoc """
  The canary's drift and rows series on /metrics sum the measurement. Red on
  03cbf323f, where they were `counter`s: every run emits all four invariants
  (zeros included), so each series climbed by 1 an hour on clean data and the
  engram-infra drift alert would fire forever.

  async: false: the series are global PromEx state.
  """
  use ExUnit.Case, async: false

  defp scrape, do: Engram.PromEx |> PromEx.get_metrics() |> IO.iodata_to_binary()

  defp value(metric, labels) do
    series = if labels == "", do: metric, else: "#{metric}\\{#{labels}\\}"

    case Regex.run(~r/^#{series} (\S+)$/m, scrape()) do
      [_, v] -> v |> Float.parse() |> elem(0)
      nil -> 0.0
    end
  end

  defp drift(invariant),
    do: value("engram_prom_ex_reliability_bookkeeping_drift_total", ~s(invariant="#{invariant}"))

  defp run(drift) do
    for {invariant, n} <- drift,
        do:
          :telemetry.execute([:engram, :bookkeeping, :drift], %{count: n}, %{invariant: invariant})
  end

  test "a clean run adds nothing; one drifted row adds exactly 1" do
    before = drift(:state_missing)
    other = drift(:counters_drift)

    run(state_missing: 0, counters_drift: 0, note_split: 0, body_drift: 0)
    assert drift(:state_missing) == before
    assert drift(:counters_drift) == other

    run(state_missing: 1, counters_drift: 0, note_split: 0, body_drift: 0)
    assert drift(:state_missing) == before + 1
    assert drift(:counters_drift) == other
  end

  test "rows checked sum the measurement" do
    metric = "engram_prom_ex_reliability_bookkeeping_canary_rows_total"
    before = value(metric, "")

    :telemetry.execute([:engram, :bookkeeping, :canary_rows], %{count: 200}, %{})
    assert value(metric, "") == before + 200
  end
end
