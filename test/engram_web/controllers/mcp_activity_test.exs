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

  test "a second call is throttled for surface_active but still counts as a tool call", %{
    conn: conn
  } do
    call(conn, "list_vaults")
    call(conn, "list_vaults")

    events = drain()
    assert Enum.count(events, &(&1["event"] == "surface_active")) == 1
    assert Enum.count(events, &(&1["event"] == "mcp_tool_called")) == 2
  end

  test "an unknown tool is labelled :unknown, never the client-supplied name", %{conn: conn} do
    call(conn, "totally_made_up_tool_name")

    for e <- drain(), e["event"] == "mcp_tool_called" do
      refute e["properties"]["tool"] =~ "made_up"
    end
  end
end
