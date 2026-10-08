defmodule Engram.PromEx.Mcp do
  @moduledoc """
  PromEx plugin for the MCP layer (`EngramWeb.McpController`).

  Subscribes to:

    * `[:engram, :mcp, :tool, :stop]` — `%{duration: native,
      result_bytes: integer}`, metadata `%{tool: atom, status: :ok |
      :error | :invalid_args}`. `:invalid_args` covers a call rejected at
      the JSON-RPC dispatch layer before any handler ran (missing/wrong-type
      arguments — see `EngramWeb.McpController.validate_tool_args/2`).

  Metrics:

    * `engram_prom_ex_mcp_tool_duration_milliseconds` — distribution
      tagged by `:tool` + `:status`.
    * `engram_prom_ex_mcp_tool_total` — counter for per-tool error rate.
    * `engram_prom_ex_mcp_tool_result_bytes` — distribution measuring
      response payload size; useful for capacity planning (LLM context
      consumption).

  Also subscribes to `[:engram, :mcp, :section_parse, :stop]` (from
  `Engram.MCP.ParseGate`) — `%{duration: native, bytes: integer}`,
  metadata `%{outcome: :ok | :too_complex | :busy | :timeout | :deadline | :error |
  :abandoned}` — for `engram_prom_ex_mcp_section_parse_duration_milliseconds`
  and `engram_prom_ex_mcp_section_parse_total`, tagged by `:outcome` only.

  Cardinality contract: `:tool` is a closed-set atom (17 listed tools plus 5
  deprecated aliases still dispatched under their own name, see
  `Engram.MCP.Tools.list/0` and `Engram.MCP.Tools.aliases/0`). `:status` is
  `:ok | :error | :invalid_args`. NEVER add user_id or args.
  """

  use PromEx.Plugin

  @stop_event [:engram, :mcp, :tool, :stop]
  @parse_event [:engram, :mcp, :section_parse, :stop]

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
        ),
        distribution(
          metric_prefix ++ [:section_parse, :duration, :milliseconds],
          event_name: @parse_event,
          measurement: :duration,
          description:
            "Section/outline markdown parse wait (slot wait + parse) by outcome; " <>
              "timeouts report the caller's timeout, not the full parse.",
          reporter_options: [
            buckets: [10, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 20_000, 60_000]
          ],
          tags: [:outcome],
          unit: {:native, :millisecond}
        ),
        counter(
          metric_prefix ++ [:section_parse, :total],
          event_name: @parse_event,
          description: "Section/outline markdown parses by outcome.",
          tags: [:outcome]
        )
      ]
    )
  end
end
