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
    lift_api_rps_cap!(user)
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

  test "changing a key's access emits api_key_access_changed, no vault ids", %{conn: conn} do
    user = insert(:user)
    vault = insert(:vault, user: user)
    {:ok, _raw, key} = Engram.Accounts.create_api_key(user, "k", {%{vault.id => "write"}, "none"})

    conn
    |> session_conn(user)
    |> patch("/api/connections/pat/#{key.id}", %{"vault_access" => %{vault.id => "read"}})
    |> json_response(200)

    all = events()
    assert Enum.find(all, &(&1["event"] == "api_key_access_changed"))
    refute inspect(all) =~ vault.id
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

  describe "vault lifecycle" do
    test "registering vaults emits vault_created with the user's vault number", %{conn: conn} do
      user = insert(:user)
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
      conn = session_conn(conn, user)

      for {name, n} <- [{"First", 1}, {"Second", 2}] do
        %{"id" => id} =
          conn
          |> post("/api/vaults/register", %{"name" => name, "client_id" => "c-#{n}"})
          |> json_response(201)

        created = Enum.find(events(), &(&1["event"] == "vault_created"))
        assert created["distinct_id"] == PostHog.analytics_id(user.email)
        assert created["properties"]["vault_id"] == id
        assert created["properties"]["vault_number"] == n
        assert created["properties"]["surface"] == "web"
        refute inspect(created) =~ name
      end
    end

    test "re-registering an existing vault emits nothing", %{conn: conn} do
      user = insert(:user)
      conn = session_conn(conn, user)
      post(conn, "/api/vaults/register", %{"name" => "V", "client_id" => "same"})
      _ = events()

      post(conn, "/api/vaults/register", %{"name" => "V", "client_id" => "same"})
      refute Enum.any?(events(), &(&1["event"] == "vault_created"))
    end

    test "deleting a vault emits vault_deleted", %{conn: conn} do
      user = insert(:user)
      conn = session_conn(conn, user)

      %{"id" => id} =
        conn
        |> post("/api/vaults/register", %{"name" => "Gone", "client_id" => "gone"})
        |> json_response(201)

      _ = events()
      conn |> delete("/api/vaults/#{id}") |> json_response(200)

      deleted = Enum.find(events(), &(&1["event"] == "vault_deleted"))
      assert deleted["properties"]["vault_id"] == id
      assert deleted["properties"]["surface"] == "web"
      assert deleted["properties"]["vaults_left"] == 0
    end
  end

  describe "connection churn" do
    test "a device link emits device_connected with a known platform", %{conn: conn} do
      user = insert(:user)
      vault = insert(:vault, user: user)

      for {platform, want} <- [{"mobile", "mobile"}, {"fridge", nil}] do
        {:ok, auth} = DeviceFlow.start_device_flow("client_1")
        {:ok, _} = DeviceFlow.authorize_device(auth.user_code, user, vault.id)

        post(conn, "/api/auth/device/token", %{
          device_code: auth.device_code,
          platform: platform
        })

        e = Enum.find(events(), &(&1["event"] == "device_connected"))
        assert e["distinct_id"] == PostHog.analytics_id(user.email)
        assert e["properties"]["platform"] == want
      end
    end

    test "revoking a device emits device_disconnected", %{conn: conn} do
      user = insert(:user)
      token = insert(:device_refresh_token, user: user, vault: insert(:vault, user: user))

      conn
      |> session_conn(user)
      |> delete("/api/connections/device/#{token.family_id}")
      |> response(204)

      assert Enum.find(events(), &(&1["event"] == "device_disconnected"))
    end

    test "revoking an MCP grant emits mcp_client_disconnected with its family", %{conn: conn} do
      user = insert(:user)
      client = insert(:oauth_client, client_name: "Claude Desktop")
      insert(:oauth_refresh_token, user_id: user.id, client_id: client.client_id)

      conn
      |> session_conn(user)
      |> delete("/api/connections/oauth/#{client.client_id}")
      |> response(204)

      e = Enum.find(events(), &(&1["event"] == "mcp_client_disconnected"))
      assert e["properties"]["via"] == "oauth"
      assert e["properties"]["client"] == "claude"
    end

    test "revoking an Obsidian OAuth grant is device_disconnected", %{conn: conn} do
      user = insert(:user)
      client = insert(:oauth_client, client_name: "Obsidian", kind: "obsidian")
      insert(:oauth_refresh_token, user_id: user.id, client_id: client.client_id)

      conn
      |> session_conn(user)
      |> delete("/api/connections/oauth/#{client.client_id}")
      |> response(204)

      all = events()
      assert Enum.find(all, &(&1["event"] == "device_disconnected"))
      refute Enum.find(all, &(&1["event"] == "mcp_client_disconnected"))
    end

    test "revoking an API key emits mcp_client_disconnected via api_key", %{conn: conn} do
      user = insert(:user)
      {:ok, _raw, key1} = Engram.Accounts.create_api_key(user, "a")
      {:ok, _raw, key2} = Engram.Accounts.create_api_key(user, "b")
      conn = session_conn(conn, user)

      conn |> delete("/api/connections/pat/#{key1.id}") |> response(204)
      conn |> delete("/api/api-keys/#{key2.id}") |> json_response(200)

      revoked = for e <- events(), e["event"] == "mcp_client_disconnected", do: e
      assert length(revoked) == 2
      assert Enum.all?(revoked, &(&1["properties"]["via"] == "api_key"))
    end
  end
end
