defmodule EngramWeb.Plugs.McpBodyParser do
  @moduledoc """
  Parses the body of `POST /api/mcp` and answers a body it cannot parse in
  JSON-RPC, not in Phoenix's default error shape (#1974).

  `Plug.Parsers` runs in the endpoint, before the router, so a malformed body
  raises before auth and before `McpErrorEnvelope` can reshape anything; the
  client got `{"errors":{"detail":"Bad Request"}}`, which no MCP client reads.

  Mounted in the endpoint AFTER `HostRewrite` (so `mcp.engram.page/` and the
  api host already carry `/api/mcp`) and immediately BEFORE the endpoint's own
  `Plug.Parsers`, with the same options. It parses only this one path; the
  endpoint parser then sees `body_params` already fetched and just merges
  params, so the body is decoded once. Every other route keeps its current
  errors.

    * not JSON (malformed, truncated, `[`) → 400, `-32700 Parse error`
    * over the endpoint's size cap → 413, `-32600 Request too large`

  Logged at info with the exception module only; a decode error's message
  quotes part of the body.
  """

  import Plug.Conn

  require Logger

  def init(parser_opts), do: Plug.Parsers.init(parser_opts)

  # `path_info`, not `request_path`: the mcp-host root rewrites to
  # `/api/mcp/`, and the router treats the trailing slash as the same route.
  def call(%Plug.Conn{method: "POST", path_info: ["api", "mcp"]} = conn, parsers) do
    Plug.Parsers.call(conn, parsers)
  rescue
    e in Plug.Parsers.ParseError -> refuse(conn, 400, -32_700, "Parse error", e)
    e in Plug.Parsers.RequestTooLargeError -> refuse(conn, 413, -32_600, "Request too large", e)
  end

  def call(conn, _parsers), do: conn

  defp refuse(conn, status, code, message, exception) do
    Logger.info(
      "mcp_parse_error",
      Engram.Logger.Metadata.with_category(:info, :http,
        reason: inspect(exception.__struct__),
        status: status
      )
    )

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      status,
      Jason.encode!(%{jsonrpc: "2.0", id: nil, error: %{code: code, message: message}})
    )
    |> halt()
  end
end
