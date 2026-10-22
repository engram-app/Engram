defmodule Engram.PromEx.ZeroInitTest do
  @moduledoc """
  The alerted counters exist at 0 from boot. Prometheus' `increase()` needs a
  prior sample, so a series whose first sample is 1 never pages: an isolated
  failure after a deploy went unseen (engram-infra #1525 review).
  """
  use ExUnit.Case, async: true

  alias Engram.PromEx.ZeroInit

  # A labelled series prints `name{...} v`, an unlabelled one `name v`.
  defp series_line?(scrape, metric, labels) do
    scrape
    |> String.split("\n")
    |> Enum.any?(fn line ->
      String.starts_with?(line, [metric <> "{", metric <> " "]) and
        Enum.all?(labels, fn {k, v} -> line =~ ~s(#{k}="#{v}") end)
    end)
  end

  test "every alerted series is on /metrics after start" do
    scrape = Engram.PromEx |> PromEx.get_metrics() |> IO.iodata_to_binary()

    for {metric, labels} <- ZeroInit.prometheus_series() do
      assert series_line?(scrape, metric, labels),
             "missing #{metric} #{inspect(labels)} on /metrics"
    end
  end

  test "the boot emit adds 0 to each series" do
    ref = make_ref()
    test = self()
    events = ZeroInit.series() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    :telemetry.attach_many(
      "zero-init-#{inspect(ref)}",
      events,
      fn event, measurements, meta, _ -> send(test, {ref, event, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("zero-init-#{inspect(ref)}") end)

    ZeroInit.run()

    for {event, measurements, meta} <- ZeroInit.series() do
      assert Enum.all?(Map.values(measurements), &(&1 == 0))
      assert_receive {^ref, ^event, ^measurements, ^meta}
    end
  end

  test "covers the search counters the increase() alerts select" do
    series = ZeroInit.prometheus_series()

    assert {"engram_prom_ex_search_hits_total", %{}} in series
    assert {"engram_prom_ex_search_text_missing_total", %{}} in series

    dropped = for {"engram_prom_ex_search_hits_dropped_total", %{reason: r}} <- series, do: r

    assert Enum.sort(dropped) ==
             Enum.sort(~w(text_undecryptable note_undecryptable payload_undecryptable))
  end

  test "covers the rebuild counters the v5 alerts select" do
    series = ZeroInit.prometheus_series()

    for metric <- ~w(rebuild_halted rebuild_meter_failed rebuild_double_pay_parked) do
      assert {"engram_prom_ex_indexing_#{metric}_total", %{}} in series
    end
  end

  test "covers each status and outcome the v5 alerts select" do
    labels = Enum.map(ZeroInit.prometheus_series(), &elem(&1, 1))
    statuses = for %{status: s} <- labels, uniq: true, do: s
    outcomes = for %{outcome: o} <- labels, uniq: true, do: o

    assert Enum.sort(statuses) ==
             Enum.sort(~w(requeue_failed remap_failed after_flip guard_rebuild both_deks_failed))

    assert "drifted" in outcomes and "rewritten" in outcomes
  end

  test "covers the reconcile cancel statuses the alert selects" do
    statuses =
      for {"engram_prom_ex_indexing_payload_reconcile_cancelled_total", %{http_status: s}} <-
            ZeroInit.prometheus_series(),
          do: s

    assert "400" in statuses
  end

  test "starts after PromEx, so its handlers are attached" do
    children = Engram.Application.children(Application.fetch_env!(:engram, Oban))
    prom_ex = Enum.find_index(children, &(&1 == Engram.PromEx))
    zero = Enum.find_index(children, &(&1 == ZeroInit))

    assert prom_ex && zero && zero > prom_ex
  end
end
