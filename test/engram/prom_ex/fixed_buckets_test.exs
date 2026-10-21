defmodule Engram.PromEx.FixedBucketsTest do
  @moduledoc """
  Every histogram in our PromEx plugins names a compiled Peep bucket module.

  Without `:peep_bucket_calculator`, `PromEx.MetricTypes.Event.build/2` runs
  `Module.create(<group>.Bucket_N, ...)` on EVERY `event_metrics/1` call. The
  app defined those modules at boot, so each call is a redefinition, which the
  code server loads with a purge: `check_process_code` against every process
  in the VM, with the code server answering nothing else until it finishes.
  Under a loaded CI partition that stalled `Application.app_dir/1` (and
  `application:start/2`) past ExUnit's 60 s timeout.

  `Engram.PromEx.Ecto` is left out: it calls `PromEx.Plugins.Ecto.event_metrics/1`,
  which builds the upstream groups' bucket modules before we drop them.
  """
  # Not async: capture_io(:stderr) captures the whole VM's stderr.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Telemetry.Metrics.Distribution

  @plugins [
    Engram.PromEx.Crdt,
    Engram.PromEx.Crypto,
    Engram.PromEx.Indexing,
    Engram.PromEx.Mcp,
    Engram.PromEx.Native,
    Engram.PromEx.Notes,
    Engram.PromEx.OAuth,
    Engram.PromEx.Profiling,
    Engram.PromEx.Qdrant,
    Engram.PromEx.RateLimiter,
    Engram.PromEx.Reliability,
    Engram.PromEx.Search,
    Engram.PromEx.Voyage,
    Engram.PromEx.WebSocket
  ]

  # The `le` boundaries each histogram exported before the calculators were
  # made explicit (origin/main 43febde99). Dashboards and alerts key on these
  # names and boundaries; a change here is a change to every panel on them.
  @scraped %{
    "engram_prom_ex_crdt_checkpoint_doc_bloat_ratio" => [1, 2, 3, 5, 10, 25, 50, 100, 500],
    "engram_prom_ex_crdt_checkpoint_doc_state_bytes" => [
      1_000,
      5_000,
      10_000,
      50_000,
      100_000,
      500_000,
      1_000_000,
      5_000_000
    ],
    "engram_prom_ex_crdt_checkpoint_doc_content_bytes" => [
      500,
      1_000,
      5_000,
      10_000,
      50_000,
      100_000,
      500_000
    ],
    "engram_prom_ex_crdt_checkpoint_doc_client_count" => [1, 2, 5, 10, 25, 50, 100, 500, 1_000],
    "engram_prom_ex_crdt_update_bytes" => [
      64,
      256,
      1_024,
      4_096,
      16_384,
      65_536,
      262_144,
      1_048_576,
      5_242_880
    ],
    "engram_prom_ex_mcp_tool_duration_milliseconds" => [
      5,
      10,
      25,
      50,
      100,
      250,
      500,
      1_000,
      5_000
    ],
    "engram_prom_ex_mcp_tool_result_bytes" => [64, 256, 1_024, 4_096, 16_384, 65_536, 262_144],
    "engram_prom_ex_profiling_sample_duration_milliseconds" => [0.5, 1, 2, 5, 10, 20, 50, 100],
    "engram_prom_ex_qdrant_request_duration_milliseconds" => [
      1,
      5,
      10,
      25,
      50,
      100,
      250,
      500,
      1_000,
      5_000
    ],
    "engram_prom_ex_voyage_embed_duration_milliseconds" => [
      50,
      100,
      250,
      500,
      1_000,
      2_000,
      3_000,
      5_000,
      10_000
    ],
    "engram_prom_ex_websocket_channel_memory_bytes" => [
      16_384,
      65_536,
      262_144,
      1_048_576,
      4_194_304,
      16_777_216,
      67_108_864
    ]
  }

  defp distributions do
    for plugin <- @plugins,
        metrics <- [plugin_metrics(plugin)],
        %Distribution{} = d <- metrics,
        do: d
  end

  defp plugin_metrics(plugin) do
    events = plugin.event_metrics(otp_app: :engram) |> List.wrap()

    polling =
      if function_exported?(plugin, :polling_metrics, 1),
        do: plugin.polling_metrics(otp_app: :engram) |> List.wrap(),
        else: []

    Enum.flat_map(events ++ polling, & &1.metrics)
  end

  test "event_metrics/1 defines no module at runtime" do
    stderr =
      capture_io(:stderr, fn ->
        # Twice: the second call is a redefinition even on a cold VM.
        for _ <- 1..2, plugin <- @plugins, do: plugin.event_metrics(otp_app: :engram)
      end)

    refute stderr =~ "redefining module"
  end

  test "every histogram names a compiled bucket calculator" do
    for d <- distributions() do
      calc = d.reporter_options[:peep_bucket_calculator]
      name = Enum.join(d.name, "_")

      assert calc, "#{name} has no :peep_bucket_calculator"

      refute calc |> Module.split() |> List.last() |> String.starts_with?("Bucket_"),
             "#{name} uses a PromEx-generated bucket module"

      assert is_list(:code.which(calc)) and :code.which(calc) != [],
             "#{name}: #{inspect(calc)} is not a compiled module"
    end
  end

  test "histogram names and le boundaries scrape exactly as before" do
    by_name = Map.new(distributions(), &{Enum.join(&1.name, "_"), &1})

    assert by_name |> Map.keys() |> Enum.sort() == @scraped |> Map.keys() |> Enum.sort()

    for {name, buckets} <- @scraped do
      d = Map.fetch!(by_name, name)
      calc = d.reporter_options[:peep_bucket_calculator]

      assert d.reporter_options[:buckets] == buckets, name
      assert calc.number_of_buckets(%{}) == length(buckets), name

      # `le` labels: Peep renders upper_bound/2 per bucket index, then +Inf.
      les = for i <- 0..length(buckets), do: calc.upper_bound(i, %{})
      assert les == Enum.map(buckets, &to_string(&1 * 1.0)) ++ ["+Inf"], name

      # A sample lands in the first bucket whose boundary is above it, as in
      # the PromEx-generated modules (both are Peep.Buckets.Custom).
      samples =
        Enum.flat_map(buckets, fn b -> [b - 1, b, b + 1, b * 1.0, b - 0.5] end) ++
          [0, 0.0, -1, 10 * List.last(buckets)]

      for v <- samples do
        assert calc.bucket_for(v, %{}) == Enum.count(buckets, &(&1 <= v)),
               "#{name} bucket_for(#{v})"
      end
    end
  end
end
