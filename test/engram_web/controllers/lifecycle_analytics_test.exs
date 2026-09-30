defmodule EngramWeb.LifecycleAnalyticsTest do
  @moduledoc """
  One-shot lifecycle milestones for the activation funnel: plugin linked, API key
  created, MCP OAuth granted. Global app env, so not async.
  """
  use EngramWeb.ConnCase, async: false

  alias Engram.Auth.DeviceFlow
  alias Engram.OAuth
  alias Engram.Observability.PostHog

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

    :ok
  end

  defp events(acc \\ []) do
    receive do
      {:posthog_body, b} -> events([b | acc])
    after
      400 -> acc
    end
  end

  defp session_conn(conn, user) do
    user = ensure_external_id(user)
    {:ok, token} = Engram.Auth.Providers.Local.issue_access_token(user.external_id, user.email)
    grant_api_write!(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  test "exchanging a device code emits plugin_linked for the keyed user", %{conn: conn} do
    user = insert(:user)
    vault = insert(:vault, user: user)
    {:ok, auth} = DeviceFlow.start_device_flow("client_1")
    {:ok, _} = DeviceFlow.authorize_device(auth.user_code, user, vault.id)

    post(conn, "/api/auth/device/token", %{device_code: auth.device_code})

    e = Enum.find(events(), &(&1["event"] == "plugin_linked"))
    assert e["distinct_id"] == PostHog.analytics_id(user.email)
  end

  test "a still-pending device code emits nothing", %{conn: conn} do
    {:ok, auth} = DeviceFlow.start_device_flow("client_1")

    post(conn, "/api/auth/device/token", %{device_code: auth.device_code})

    refute Enum.any?(events(), &(&1["event"] == "plugin_linked"))
  end

  test "creating an API key emits api_key_created and never the key", %{conn: conn} do
    user = insert(:user)

    resp =
      conn
      |> session_conn(user)
      |> post("/api/api-keys", %{"name" => "laptop"})
      |> json_response(200)

    all = events()
    e = Enum.find(all, &(&1["event"] == "api_key_created"))
    assert e["distinct_id"] == PostHog.analytics_id(user.email)
    refute inspect(all) =~ resp["key"]
  end

  test "approving MCP consent emits mcp_oauth_granted", %{conn: conn} do
    user = insert(:user)
    vault = insert(:vault, user: user)

    {:ok, client} =
      OAuth.register_client(%{
        "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"],
        "client_name" => "Claude"
      })

    conn
    |> session_conn(user)
    |> post("/api/oauth/authorize/consent", %{
      "client_id" => client.client_id,
      "redirect_uri" => hd(client.redirect_uris),
      "response_type" => "code",
      "code_challenge" => "abc123challenge",
      "code_challenge_method" => "S256",
      "state" => "xyz",
      "scope" => "mcp",
      "vault_choice" => "vault:#{vault.id}"
    })
    |> json_response(200)

    e = Enum.find(events(), &(&1["event"] == "mcp_oauth_granted"))
    assert e["distinct_id"] == PostHog.analytics_id(user.email)
  end
end
