defmodule Engram.PromEx.StorageTest do
  @moduledoc """
  Pins the rendered /metrics text under the PromEx storage adapter.

  Dashboards and alerts in engram-infra select on metric names, `le` values
  and `_sum`/`_count`, so swapping the reporter must keep all of them. Peep
  replaced `PromEx.Storage.Core` because Core's exporter ran a regex per
  series and three `String.replace` calls per label per bucket line, ~12% of
  app CPU at a 15 s scrape interval.

  async: false. The PromEx collector is one process shared by the whole app,
  and the counts asserted below must not move under a concurrent test.
  """
  use EngramWeb.ConnCase, async: false

  @http "engram_prom_ex_phoenix_http_request_duration_milliseconds"
  # PromEx.Plugins.Phoenix `http_metrics/2` duration buckets.
  @http_buckets [10, 100, 500, 1_000, 5_000, 10_000, 30_000]
  @dropped "engram_prom_ex_search_hits_dropped_total"
  @bloat "engram_prom_ex_crdt_checkpoint_doc_bloat_ratio"
  @state_bytes "engram_prom_ex_crdt_checkpoint_doc_state_bytes"

  # One Prometheus text-format sample line. A label value may contain any
  # character except a raw `"`, `\` or newline, which must arrive escaped.
  @sample ~r/^[a-zA-Z_][a-zA-Z0-9_]*(\{[a-zA-Z_][a-zA-Z0-9_]*="(?:[^"\\\n]|\\["\\n])*"(,[a-zA-Z_][a-zA-Z0-9_]*="(?:[^"\\\n]|\\["\\n])*")*\})? -?[0-9.e+\-]+$|^[a-zA-Z_][a-zA-Z0-9_]*(\{.*\})? \+?Inf$/

  defp scrape, do: Engram.PromEx |> PromEx.get_metrics() |> IO.iodata_to_binary()

  defp lines(body, prefix),
    do: body |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, prefix))

  defp value(body, prefix) do
    case lines(body, prefix) do
      [line] -> line |> String.split(" ") |> List.last() |> String.to_integer()
      [] -> 0
    end
  end

  test "the configured storage adapter is Peep" do
    assert PromEx.storage_adapter() == PromEx.Storage.Peep
  end

  test "http histogram keeps its name, configured le boundaries, +Inf, _sum and _count",
       %{conn: conn} do
    get(conn, "/api/health")
    body = scrape()

    bucket_lines =
      body |> lines(@http <> "_bucket{") |> Enum.filter(&(&1 =~ ~s(path="/api/health")))

    les =
      bucket_lines
      |> Enum.map(&(Regex.run(~r/le="([^"]+)"/, &1) |> List.last()))
      |> Enum.uniq()

    # Compared as numbers: Peep renders `1.0e3` where Core rendered `1000`, and
    # the scraper normalizes both to `1000.0` on ingest (what prod stores), so
    # only the numeric boundary is contractual.
    {inf, finite} = Enum.split_with(les, &(&1 == "+Inf"))
    assert inf == ["+Inf"]

    assert finite |> Enum.map(&elem(Float.parse(&1), 0)) |> Enum.sort() ==
             Enum.map(@http_buckets, &(&1 * 1.0))

    assert Enum.any?(lines(body, @http <> "_sum{"), &(&1 =~ ~s(path="/api/health")))
    assert Enum.any?(lines(body, @http <> "_count{"), &(&1 =~ ~s(path="/api/health")))
    assert body =~ "# TYPE #{@http} histogram"
  end

  test "label values with a quote, backslash and newline render as valid text format" do
    :telemetry.execute([:engram, :search, :hit_dropped], %{count: 1}, %{reason: "a\"b\\c\nd"})
    body = scrape()

    assert body =~ ~S(engram_prom_ex_search_hits_dropped_total{reason="a\"b\\c\nd"} )

    for line <- String.split(body, "\n"),
        line != "",
        not String.starts_with?(line, "#") do
      assert line =~ @sample, "invalid exposition line: #{inspect(line)}"
    end

    assert lines(body, @dropped) != []
  end

  # Peep records 1 for a measurement KEY that is absent from the event (it
  # assumes a counter), where Core skipped it. A nil value is skipped by both.
  # Emitters that mean "no sample" must therefore pass nil, never omit the key.
  test "a nil measurement takes no sample while its siblings still do" do
    before = scrape()

    :telemetry.execute(
      [:engram, :crdt, :checkpoint_doc],
      %{state_bytes: 10, content_bytes: 0, client_count: 1, bloat_ratio: nil},
      %{}
    )

    after_body = scrape()

    assert value(after_body, @state_bytes <> "_count") ==
             value(before, @state_bytes <> "_count") + 1

    assert value(after_body, @bloat <> "_count") == value(before, @bloat <> "_count")
  end
end
