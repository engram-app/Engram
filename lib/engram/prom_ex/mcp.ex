defmodule Engram.PromEx.Mcp do
  @moduledoc """
  PromEx plugin for the MCP layer (`EngramWeb.McpController`).

  Subscribes to:

    * `[:engram, :mcp, :tool, :stop]` — `%{duration: native,
      result_bytes: integer}`, metadata `%{tool: atom, status: :ok |
      :error}`.

  Metrics:

    * `engram_prom_ex_mcp_tool_duration_milliseconds` — distribution
      tagged by `:tool` + `:status`.
    * `engram_prom_ex_mcp_tool_total` — counter for per-tool error rate.
    * `engram_prom_ex_mcp_tool_result_bytes` — distribution measuring
      response payload size; useful for capacity planning (LLM context
      consumption).

  Cardinality contract: `:tool` is a closed-set atom (~16 tools, see
  `Engram.MCP.Tools.list/0`). `:status` is `:ok | :error`. NEVER add
  user_id or args.
  """

  use PromEx.Plugin

  @stop_event [:engram, :mcp, :tool, :stop]

  @impl true
  def event_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    metric_prefix = PromEx.metric_prefix(otp_app, :mcp)

    Event.build(
      :engram_mcp_event_metrics,
      [
        distribution(
          metric_prefix ++ [:tool, :duration, :milliseconds],
          event_name: @stop_event,
          measurement: :duration,
          description: "MCP tool dispatch latency by tool.",
          reporter_options: [
            buckets: [5, 10, 25, 50, 100, 250, 500, 1_000, 5_000]
          ],
          tags: [:tool, :status],
          unit: {:native, :millisecond}
        ),
        counter(
          metric_prefix ++ [:tool, :total],
          event_name: @stop_event,
          description: "MCP tool calls by tool + status.",
          tags: [:tool, :status]
        ),
        distribution(
          metric_prefix ++ [:tool, :result_bytes],
          event_name: @stop_event,
          measurement: :result_bytes,
          description: "MCP tool result payload size in bytes (LLM context cost).",
          reporter_options: [
            buckets: [64, 256, 1_024, 4_096, 16_384, 65_536, 262_144]
          ],
          tags: [:tool]
        )
      ]
    )
  end
end
