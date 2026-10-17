defmodule Engram.PromEx.Ecto do
  @moduledoc """
  Slim replacement for `PromEx.Plugins.Ecto`'s query metrics.

  PromEx's group recorded six histograms per query, three of them tagged by
  `source` (~37 tables x commands x 7 buckets), and in MILLISECONDS. Under
  Peep a histogram `_sum` adds `round(value)` per sample, so a 0.15 ms queue
  or decode time added 0 and every sub-ms average read as zero. This plugin
  keeps PromEx's repo init gauges and its telemetry proxy (it delegates to
  `PromEx.Plugins.Ecto` for both) and replaces the query group with:

    * `total_time_microseconds` histogram by `repo` + `command` (no `source`),
      PromEx's millisecond buckets x1000;
    * per `source`: a query counter (also by `command`, so source-less
      transaction control stays separable) and integer microsecond sums of
      total and queue time. Average = sum / count;
    * per `repo`: integer microsecond sums of decode and idle time.

  Dropped outright: execution_time (total_time covers it, and Tempo has
  per-span query time) and results_returned (nothing read it).

  Every timing is converted to an INTEGER microsecond count here, not via
  `unit:`. Telemetry.Metrics' native->microsecond ratio is a float, and a
  float sample makes Peep's ETS `update_counter` raise on a Sum. A timing
  Ecto did not measure (queue_time inside a transaction) is nil, which takes
  no sample; an absent key would record Peep's counter default of 1.
  """
  use PromEx.Plugin

  @query_event [:prom_ex, :plugin, :ecto, :query]

  @impl true
  def event_metrics(opts) do
    prefix =
      Keyword.get(opts, :metric_prefix, PromEx.metric_prefix(opts[:otp_app], :ecto)) ++
        [:repo, :query]

    init_group =
      opts
      |> PromEx.Plugins.Ecto.event_metrics()
      |> Enum.reject(&(&1.group_name == :ecto_query_event_metrics))

    init_group ++
      [
        Event.build(:engram_ecto_query_event_metrics, [
          distribution(prefix ++ [:total_time, :microseconds],
            event_name: @query_event,
            measurement: us(:total_time),
            description: "Total query time (queue + query + decode), microseconds.",
            tags: [:repo, :command],
            tag_values: &tag_values/1,
            reporter_options: [
              buckets: [10_000, 50_000, 250_000, 2_500_000, 10_000_000, 30_000_000]
            ]
          ),
          counter(prefix ++ [:source, :queries, :total],
            event_name: @query_event,
            description: "Queries by source table and command.",
            tags: [:repo, :source, :command],
            tag_values: &tag_values/1
          ),
          sum(prefix ++ [:source, :time, :microseconds, :total],
            event_name: @query_event,
            measurement: us(:total_time),
            description: "Total query time by source table, microseconds.",
            tags: [:repo, :source],
            tag_values: &tag_values/1
          ),
          sum(prefix ++ [:source, :queue_time, :microseconds, :total],
            event_name: @query_event,
            measurement: us(:queue_time),
            description: "Time waiting for a pool connection by source table, microseconds.",
            tags: [:repo, :source],
            tag_values: &tag_values/1
          ),
          sum(prefix ++ [:decode_time, :microseconds, :total],
            event_name: @query_event,
            measurement: us(:decode_time),
            description: "Time decoding result rows, microseconds.",
            tags: [:repo],
            tag_values: &tag_values/1
          ),
          sum(prefix ++ [:idle_time, :microseconds, :total],
            event_name: @query_event,
            measurement: us(:idle_time),
            description: "Time the connection sat idle before checkout, microseconds.",
            tags: [:repo],
            tag_values: &tag_values/1
          )
        ])
      ]
  end

  defp us(key) do
    fn
      %{^key => native} when is_integer(native) ->
        System.convert_time_unit(native, :native, :microsecond)

      _ ->
        nil
    end
  end

  # Same label values PromEx.Plugins.Ecto produced, so dashboards keep their
  # `repo`, `source` and `command` selectors.
  defp tag_values(%{repo: repo} = meta) do
    %{
      repo: repo |> Atom.to_string() |> String.trim_leading("Elixir."),
      source: source(meta[:source]),
      command: command(meta[:result])
    }
  end

  defp source(source) when is_binary(source), do: source
  defp source(source) when is_atom(source) and not is_nil(source), do: Atom.to_string(source)
  defp source(_), do: "source_unavailable"

  defp command({:ok, %_{command: command}}) when is_atom(command), do: Atom.to_string(command)
  defp command(_), do: "unavailable"
end
