defmodule EngramWeb.Plugs.WebActivityTest do
  use EngramWeb.ConnCase, async: false

  alias Engram.Observability.PostHog
  alias EngramWeb.Plugs.WebActivity

  setup do
    EngramWeb.RateLimiter.reset_buckets!()
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

    %{user: insert(:user)}
  end

  defp run(conn, user, extra) do
    conn = Plug.Conn.assign(conn, :current_user, user)

    Enum.reduce(extra, conn, fn {k, v}, c -> Plug.Conn.assign(c, k, v) end)
    |> WebActivity.call([])
  end

  test "a Clerk-authenticated request counts as web", %{conn: conn, user: user} do
    run(conn, user, [])

    assert_receive {:posthog_body, body}, 1_000
    assert body["event"] == "surface_active"
    assert body["properties"]["surface"] == "web"
    assert body["distinct_id"] == PostHog.analytics_id(user.email)
  end

  test "an API-key request is not web", %{conn: conn, user: user} do
    run(conn, user, current_api_key: %{id: 1})
    refute_receive {:posthog_body, _}, 300
  end

  test "a device / OAuth / MCP token request is not web", %{conn: conn, user: user} do
    run(conn, user, current_auth_method: :internal_jwt)
    refute_receive {:posthog_body, _}, 300
  end

  test "is a no-op without a current_user and always passes the conn through", %{conn: conn} do
    assert ^conn = WebActivity.call(conn, [])
    refute_receive {:posthog_body, _}, 200
  end

  test "repeat requests are throttled to one event", %{conn: conn, user: user} do
    for _ <- 1..4, do: run(conn, user, [])

    assert_receive {:posthog_body, _}, 1_000
    refute_receive {:posthog_body, _}, 300
  end
end
