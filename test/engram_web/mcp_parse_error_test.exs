defmodule EngramWeb.McpParseErrorTest do
  @moduledoc """
  Malformed JSON on the MCP endpoint answers a JSON-RPC parse error (#1974).

  `Plug.Parsers` raises in the endpoint, before the router, so neither auth
  nor `McpErrorEnvelope` runs and the client used to get Phoenix's
  `{"errors":{"detail":"Bad Request"}}`, which no MCP client can read.
  """
  # async: false — sets :host_rewrite app env.
  use EngramWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  require Logger

  @malformed ~s({"jsonrpc":"2.0","id":1,"method":)
  @parse_error %{
    "jsonrpc" => "2.0",
    "id" => nil,
    "error" => %{"code" => -32_700, "message" => "Parse error"}
  }

  defp raw_post(conn, url, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> post(url, body)
  end

  defp rendered(%Plug.Conn{} = conn) do
    {conn.status, conn |> get_resp_header("content-type") |> hd(), Jason.decode!(conn.resp_body)}
  end

  defp rendered({status, headers, body}) do
    content_type = headers |> List.keyfind("content-type", 0) |> elem(1)
    {status, content_type, Jason.decode!(body)}
  end

  test "malformed JSON on /api/mcp is a JSON-RPC parse error, and is logged without the body" do
    # Test config logs at :warning; lift it for this (non-async) test.
    prior = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: prior) end)

    log =
      capture_log([level: :info], fn ->
        assert {400, content_type, @parse_error} =
                 rendered(raw_post(build_conn(), "/api/mcp", @malformed))

        assert content_type =~ "application/json"
      end)

    assert log =~ "mcp_parse_error"
    refute log =~ ~s("method":)
  end

  test "an unterminated array is a parse error too" do
    assert {400, _, @parse_error} =
             rendered(raw_post(build_conn(), "/api/mcp", "["))
  end

  test "the mcp host root (rewritten to /api/mcp) gets the same answer" do
    prior = Application.get_env(:engram, :host_rewrite)

    Application.put_env(:engram, :host_rewrite,
      api_host: "api.engram.page",
      mcp_host: "mcp.engram.page"
    )

    on_exit(fn ->
      if prior,
        do: Application.put_env(:engram, :host_rewrite, prior),
        else: Application.delete_env(:engram, :host_rewrite)
    end)

    for url <- ["http://mcp.engram.page/", "http://api.engram.page/api/mcp"] do
      assert {400, _, @parse_error} =
               rendered(raw_post(build_conn(), url, @malformed))
    end
  end

  test "other routes keep the default error shape" do
    assert {400, _, %{"errors" => %{"detail" => "Bad Request"}}} =
             rendered(
               assert_error_sent(400, fn -> raw_post(build_conn(), "/api/notes", @malformed) end)
             )
  end

  test "an oversized body on /api/mcp is a JSON-RPC shaped 413" do
    huge =
      ~s({"jsonrpc":"2.0","id":1,"method":"x","params":{"p":") <>
        String.duplicate("a", EngramWeb.Endpoint.max_body_bytes() + 1) <> ~s("}})

    assert {413, _, %{"jsonrpc" => "2.0", "id" => nil, "error" => %{"code" => -32_600}}} =
             rendered(raw_post(build_conn(), "/api/mcp", huge))
  end

  # Already handled before this change, on the controller's existing status
  # (200, JSON-RPC error in the body); pinned so it stays JSON-RPC shaped.
  describe "authenticated" do
    setup :authed_api_conn

    test "an empty body is Invalid Request", %{conn: conn} do
      body = conn |> raw_post("/api/mcp", "") |> json_response(200)
      assert body["error"]["code"] == -32_600
    end

    test "a valid JSON array that is not a JSON-RPC request is Invalid Request", %{conn: conn} do
      body = conn |> raw_post("/api/mcp", "[1, 2]") |> json_response(200)
      assert body["error"]["code"] == -32_600
    end
  end
end
