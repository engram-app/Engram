defmodule EngramWeb.McpActivityTest do
  @moduledoc """
  MCP tool calls feed PostHog: a throttled `surface_active` (who is here) and an
  unthrottled `mcp_tool_called` (what they use). Global app env, so not async.
  """
  use EngramWeb.ConnCase, async: false

  alias Engram.Observability.PostHog

  setup %{conn: conn} do
    EngramWeb.RateLimiter.reset_buckets!()
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, _vault, _} = Engram.Vaults.register_vault(user, "V", Ecto.UUID.generate())
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "k")
    grant_api_write!(user)

    bypass = Bypass.open()

    prior =
      {Application.get_env(:engram, :posthog_key), Application.get_env(:engram, :posthog_host)}

    Application.put_env(:engram, :posthog_key, "phc_test_token")
    Application.put_env(:engram, :posthog_host, "http://localhost:#{bypass.port}")

    on_exit(fn ->
      {key, host} = prior
      Application.put_env(:engram, :posthog_key, key)
      Application.put_env(:engram, :posthog_host, host)
    end)

    parent = self()

    Bypass.stub(bypass, "POST", "/capture/", fn c ->
      {:ok, body, c} = Plug.Conn.read_body(c)
      send(parent, {:posthog_body, Jason.decode!(body)})
      Plug.Conn.resp(c, 200, "1")
    end)

    %{conn: put_req_header(conn, "authorization", "Bearer #{api_key}"), user: user}
  end

  defp call(conn, name) do
    post(conn, "/api/mcp", %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => %{}}
    })
  end

  defp drain(acc \\ []) do
    receive do
      {:posthog_body, b} -> drain([b | acc])
    after
      400 -> acc
    end
  end

  test "a tool call emits surface_active and mcp_tool_called for the keyed user", %{
    conn: conn,
    user: user
  } do
    call(conn, "list_vaults")

    events = drain()
    id = PostHog.analytics_id(user.email)

    active = Enum.find(events, &(&1["event"] == "surface_active"))
    assert active["distinct_id"] == id
    assert active["properties"]["surface"] == "mcp"

    called = Enum.find(events, &(&1["event"] == "mcp_tool_called"))
    assert called["distinct_id"] == id
    assert called["properties"]["tool"] == "list_vaults"
    assert called["properties"]["status"] == "ok"
  end

  test "repeat calls: surface_active once, mcp_tool_called once per tool per window", %{
    conn: conn
  } do
    call(conn, "list_vaults")
    call(conn, "list_vaults")
    call(conn, "list_tags")

    events = drain()
    assert Enum.count(events, &(&1["event"] == "surface_active")) == 1

    tools =
      for e <- events, e["event"] == "mcp_tool_called", do: e["properties"]["tool"]

    assert Enum.sort(tools) == ["list_tags", "list_vaults"]
  end

  test "an invalid-args call still counts as MCP activity", %{conn: conn} do
    post(conn, "/api/mcp", %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => "list_vaults", "arguments" => %{"foo" => "x"}}
    })

    events = drain()
    assert Enum.any?(events, &(&1["event"] == "surface_active"))

    called = Enum.find(events, &(&1["event"] == "mcp_tool_called"))
    assert called["properties"]["status"] == "invalid_args"
  end

  test "an unknown tool name never reaches PostHog", %{conn: conn} do
    call(conn, "totally_made_up_tool_name")

    assert drain() == []
  end

  defp initialize(conn, client_info) do
    post(conn, "/api/mcp", %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{"protocolVersion" => "2025-03-26", "clientInfo" => client_info}
    })
  end

  test "initialize emits mcp_client_connected with a bucketed client family", %{
    conn: conn,
    user: user
  } do
    initialize(conn, %{"name" => "Claude-Code", "version" => "2.1.0"})

    events = drain()
    connected = Enum.find(events, &(&1["event"] == "mcp_client_connected"))
    assert connected["distinct_id"] == PostHog.analytics_id(user.email)
    assert connected["properties"]["client"] == "claude-code"
    assert Enum.any?(events, &(&1["event"] == "surface_active"))
  end

  test "an unrecognised or hostile client name is bucketed as other", %{conn: conn} do
    initialize(conn, %{"name" => "<script>alert(1)</script>" <> String.duplicate("x", 500)})

    connected = Enum.find(drain(), &(&1["event"] == "mcp_client_connected"))
    assert connected["properties"]["client"] == "other"
  end

  test "a non-object clientInfo is bucketed as other, not a crash", %{conn: conn} do
    conn = initialize(conn, "claude")

    assert json_response(conn, 200)["result"]["serverInfo"]
    connected = Enum.find(drain(), &(&1["event"] == "mcp_client_connected"))
    assert connected["properties"]["client"] == "other"
  end
end
