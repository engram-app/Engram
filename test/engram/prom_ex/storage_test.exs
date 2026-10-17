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

  # Only duration + count are read; a response-size histogram per route was
  # ~8 buckets of series nothing graphed usefully.
  test "http keeps duration and request count with their labels, drops response size",
       %{conn: conn} do
    get(conn, "/api/health")
    body = scrape()

    for family <- [@http <> "_count{", "engram_prom_ex_phoenix_http_requests_total{"] do
      [line | _] = body |> lines(family) |> Enum.filter(&(&1 =~ ~s(path="/api/health")))

      for label <- ~w(status method path controller action host),
          do: assert(line =~ ~s(#{label}="), "#{family} lost #{label}")
    end

    assert lines(body, "engram_prom_ex_phoenix_http_response_size") == []
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

  # PromEx turns a distribution's `buckets:` into a Peep bucket module only for
  # EVENT metrics (PromEx.MetricTypes.Event.build/2). A polling distribution
  # keeps whatever Peep defaults to, an exponential series with nothing in
  # common with the configured boundaries, and dashboards selecting on `le`
  # silently read nothing. Checked against the metrics the RUNNING collector
  # holds, so a new histogram of either kind is covered without listing it.
  test "every histogram, event and polling, carries its configured buckets" do
    distributions =
      for %Telemetry.Metrics.Distribution{} = d <- running_metrics(), do: d

    assert Enum.any?(
             distributions,
             &(&1.name == [:engram, :prom_ex, :websocket, :channel_memory, :bytes])
           )

    for %{reporter_options: opts} = d <- distributions, buckets = opts[:buckets] do
      {module, config} = Peep.Buckets.config(d)

      assert module.number_of_buckets(config) == length(:lists.usort(buckets)),
             "#{Enum.join(d.name, "_")}: #{inspect(module)} does not use its configured buckets"
    end
  end

  describe "Ecto query metrics" do
    @ecto "engram_prom_ex_ecto_repo_query_"

    # Emitted on PromEx's proxy event, not the repo's own, so no Engram
    # handler on `[:engram, :repo, :query]` sees a synthetic query.
    defp seed_query(source, us) do
      :telemetry.execute(
        [:prom_ex, :plugin, :ecto, :query],
        %{
          total_time: native(us.total),
          queue_time: native(us.queue),
          decode_time: native(us.decode),
          idle_time: native(us.idle)
        },
        %{repo: Engram.Repo, source: source, result: {:ok, %Postgrex.Result{command: :select}}}
      )
    end

    defp native(us), do: System.convert_time_unit(us, :microsecond, :native)

    defp labelled(body, family, label) do
      body |> lines(family <> "{") |> Enum.filter(&(&1 =~ label)) |> Enum.map(&sample/1)
    end

    defp sample(line), do: line |> String.split(" ") |> List.last() |> String.to_integer()

    test "exposes only the slim microsecond families" do
      seed_query("zz_probe", %{total: 150, queue: 40, decode: 3, idle: 7})
      body = scrape()

      for family <- ~w(total_time_microseconds_bucket total_time_microseconds_sum
                       total_time_microseconds_count source_queries_total
                       source_time_microseconds_total source_queue_time_microseconds_total
                       decode_time_microseconds_total idle_time_microseconds_total) do
        assert lines(body, @ecto <> family) != [], "missing #{@ecto <> family}"
      end

      for gone <- ~w(execution_time results_returned total_time_milliseconds
                     queue_time_milliseconds decode_time_milliseconds idle_time_milliseconds) do
        assert lines(body, @ecto <> gone) == [], "#{@ecto <> gone} should be dropped"
      end

      refute Enum.any?(lines(body, @ecto <> "total_time_microseconds"), &(&1 =~ "source="))
    end

    # Peep adds round(value) per sample to an integer `_sum`: in milliseconds
    # a 0.15 ms query added 0 and every sub-ms average read as zero.
    test "sums sub-millisecond time as integer microseconds" do
      src = ~s(source="zz_sub_ms")
      before = scrape()
      seed_query("zz_sub_ms", %{total: 150, queue: 40, decode: 3, idle: 7})
      seed_query("zz_sub_ms", %{total: 150, queue: 40, decode: 3, idle: 7})
      body = scrape()

      delta = fn family, label ->
        Enum.sum(labelled(body, @ecto <> family, label)) -
          Enum.sum(labelled(before, @ecto <> family, label))
      end

      assert delta.("source_queries_total", src) == 2
      assert delta.("source_time_microseconds_total", src) == 300
      assert delta.("source_queue_time_microseconds_total", src) == 80
      assert delta.("decode_time_microseconds_total", ~s(repo="Engram.Repo")) >= 6
      assert delta.("idle_time_microseconds_total", ~s(repo="Engram.Repo")) >= 14
    end

    # Ecto omits queue_time inside a transaction (no checkout) and idle_time
    # likewise. An absent key must add nothing, not Peep's counter default 1.
    test "an absent timing adds nothing to its sum" do
      src = ~s(source="zz_in_txn")
      before = scrape()

      :telemetry.execute(
        [:prom_ex, :plugin, :ecto, :query],
        %{total_time: native(500)},
        %{
          repo: Engram.Repo,
          source: "zz_in_txn",
          result: {:ok, %Postgrex.Result{command: :select}}
        }
      )

      body = scrape()
      assert labelled(before, @ecto <> "source_queue_time_microseconds_total", src) == []
      assert labelled(body, @ecto <> "source_queue_time_microseconds_total", src) == []
      assert labelled(body, @ecto <> "source_time_microseconds_total", src) == [500]
    end
  end

  # Series budget for one event of each trimmed kind, under label values no
  # other test uses so every series is new. Before the 2026-10 cardinality
  # cut the same events rendered 103 series (measured on the parent commit);
  # now 8.
  test "one event per trimmed metric family adds only its budgeted series" do
    ecto = fn source ->
      :telemetry.execute(
        [:prom_ex, :plugin, :ecto, :query],
        %{total_time: 1_000, queue_time: 1_000},
        %{repo: Engram.Repo, source: source, result: {:ok, %Postgrex.Result{command: :select}}}
      )
    end

    # Warms the per-repo series so only the per-source ones are new below.
    ecto.("zz_budget_warm")
    before = series_count(scrape())
    ecto.("zz_budget")

    :telemetry.execute(
      [:engram, :nif, :call, :stop],
      %{duration: 1_000, native_peak_bytes: 1, input_bytes: 1},
      %{nif: :zz_budget, dirty: false}
    )

    :telemetry.execute(
      [:engram, :search, :request, :stop],
      %{duration: 1_000, result_count: 1},
      %{status: :zz_budget, cross_vault: false, rerank: :off}
    )

    :telemetry.execute([:engram, :mcp, :section_parse, :stop], %{duration: 1, bytes: 1}, %{
      outcome: :zz_budget
    })

    :telemetry.execute([:engram, :cimd, :fetch], %{duration_ms: 1}, %{
      kind: :zz_budget,
      result: :ok,
      reason: nil
    })

    :telemetry.execute([:engram, :crypto, :decrypt_batch], %{duration_us: 1, count: 1}, %{
      kind: :zz_budget
    })

    # Ecto: source queries + source time + source queue (total_time histogram
    # and decode/idle are per repo/command, already present). NIF: count + sum.
    # Search, section_parse, cimd: one counter each. decrypt_batch: none.
    assert series_count(scrape()) - before == 8
  end

  defp series_count(body),
    do: body |> String.split("\n") |> Enum.count(&(&1 != "" and not String.starts_with?(&1, "#")))

  defp running_metrics do
    Engram.PromEx.__metrics_collector_name__()
    |> Peep.Persistent.fetch()
    |> Peep.Persistent.ids_to_metrics()
    |> Map.values()
  end
end
