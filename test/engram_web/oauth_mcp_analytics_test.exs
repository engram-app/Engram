defmodule EngramWeb.OAuthMcpAnalyticsTest do
  @moduledoc """
  The MCP / OAuth connection funnel reaches PostHog through `Engram.Analytics`
  (#1974). Before this, only `mcp_oauth_granted` (no props) and an
  initialize-only `mcp_client_connected` existed, so a connector that
  authorized and then died on refresh left no trace in product analytics.

  Asserts on what reaches the PostHog wire (Bypass), not on what the app
  meant to send. Global app env, so not async.
  """
  use EngramWeb.ConnCase, async: false

  import Engram.OAuthHelpers, only: [code_from_redirect: 1, pkce_pair: 0]
  import Mox

  alias Engram.Auth.Providers.Local
  alias Engram.OAuth
  alias Engram.OAuth.Cimd.FetcherMock
  alias Engram.OAuth.Cimd.Jwks
  alias Engram.OAuth.Client
  alias Engram.Observability.PostHog

  @redirect "https://claude.ai/api/mcp/auth_callback"

  setup :verify_on_exit!

  setup do
    EngramWeb.RateLimiter.reset_buckets!()
    Engram.Cache.clear_local(:jwks)
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

    {:ok, client} =
      OAuth.register_client(%{"redirect_uris" => [@redirect], "client_name" => "Claude"})

    user = insert(:user)
    %{client: client, user: user}
  end

  defp drain(acc \\ []) do
    receive do
      {:posthog_body, b} -> drain([b | acc])
    after
      400 -> acc
    end
  end

  defp event(events, name), do: Enum.find(events, &(&1["event"] == name))

  defp authorize_params(client, challenge) do
    %{
      "client_id" => client.client_id,
      "redirect_uri" => @redirect,
      "response_type" => "code",
      "code_challenge" => challenge,
      "code_challenge_method" => "S256",
      "state" => "s",
      "scope" => "mcp offline_access openid"
    }
  end

  defp mint_code(client, user, challenge) do
    {:ok, validated} = OAuth.validate_authorization_request(authorize_params(client, challenge))
    {:ok, url} = OAuth.mint_authorization_code(user, validated, :all, nil)
    code_from_redirect(url)
  end

  defp exchange(client, code, verifier) do
    post(build_conn(), "/oauth/token", %{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => @redirect,
      "client_id" => client.client_id,
      "code_verifier" => verifier
    })
  end

  test "authorize emits mcp_oauth_authorize_started, anonymously", %{client: client} do
    {_verifier, challenge} = pkce_pair()
    get(build_conn(), "/oauth/authorize", authorize_params(client, challenge))

    e = event(drain(), "mcp_oauth_authorize_started")
    assert e["properties"]["$process_person_profile"] == false
    assert e["properties"]["client"] == "claude"
    assert e["properties"]["registration"] == "dcr"
    assert e["properties"]["scopes_requested"] == ["mcp", "offline_access", "openid"]
    assert e["properties"]["scopes_granted"] == ["mcp"]
  end

  test "consent emits mcp_oauth_granted with client and scopes", %{client: client, user: user} do
    user = ensure_external_id(user)
    insert(:vault, user: user)
    {:ok, token} = Local.issue_access_token(user.external_id, user.email)
    {_verifier, challenge} = pkce_pair()

    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> post("/api/oauth/authorize/consent", authorize_params(client, challenge))
    |> json_response(200)

    e = event(drain(), "mcp_oauth_granted")
    assert e["distinct_id"] == PostHog.analytics_id(user.email)
    assert e["properties"]["client"] == "claude"
    assert e["properties"]["registration"] == "dcr"
    assert e["properties"]["scopes_granted"] == ["mcp"]
    # No User-Agent on this request.
    assert e["properties"]["device"] == "unknown"
    assert e["properties"]["grant_id"] =~ ~r/^[0-9a-f]{16}$/
  end

  @iphone "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

  # The exact join: the grant id on mcp_oauth_granted is the one on the
  # exchange of that code, and never the code itself.
  test "grant_id joins a mobile consent to its exchange", %{client: client, user: user} do
    user = ensure_external_id(user)
    insert(:vault, user: user)
    {:ok, token} = Local.issue_access_token(user.external_id, user.email)
    {verifier, challenge} = pkce_pair()

    %{"redirect_uri" => redirect} =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("user-agent", @iphone)
      |> post("/api/oauth/authorize/consent", authorize_params(client, challenge))
      |> json_response(200)

    code = code_from_redirect(redirect)

    build_conn()
    |> put_req_header("user-agent", "codex-mcp-client/0.46.0")
    |> post("/oauth/token", %{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => @redirect,
      "client_id" => client.client_id,
      "code_verifier" => verifier
    })
    |> json_response(200)

    events = drain()
    granted = event(events, "mcp_oauth_granted")
    issued = event(events, "mcp_oauth_token_issued")
    assert granted["properties"]["device"] == "mobile"
    assert issued["properties"]["client_agent"] == "codex"
    assert is_binary(granted["properties"]["grant_id"])
    assert issued["properties"]["grant_id"] == granted["properties"]["grant_id"]
    refute granted["properties"]["grant_id"] =~ code
  end

  test "a refused exchange of a known code carries its grant_id", %{client: client, user: user} do
    {_verifier, challenge} = pkce_pair()
    json_response(exchange(client, mint_code(client, user, challenge), "wrong-verifier"), 400)

    e = event(drain(), "mcp_oauth_token_failed")
    assert e["properties"]["grant_id"] =~ ~r/^[0-9a-f]{16}$/
    assert e["properties"]["client_agent"] == "claude"
  end

  test "a refused refresh carries reason and client_agent", %{client: client} do
    build_conn()
    |> put_req_header("user-agent", "openai-connectors-oauth/1.0")
    |> post("/oauth/token", %{
      "grant_type" => "refresh_token",
      "refresh_token" => "engram_oauth_rt_nope",
      "client_id" => client.client_id
    })
    |> json_response(400)

    e = event(drain(), "mcp_oauth_token_failed")
    assert e["properties"]["grant_type"] == "refresh_token"
    assert e["properties"]["reason"] == "refresh_token_unknown"
    assert e["properties"]["client_agent"] == "chatgpt"
    refute Map.has_key?(e["properties"], "grant_id")
  end

  # engram_prom_ex_oauth_consent_total: one per minted code, by client family.
  test "consent emits one [:engram, :oauth, :consent] event with the client family", %{
    client: client,
    user: user
  } do
    test_pid = self()
    handler = "oauth-consent-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:engram, :oauth, :consent],
      fn _e, measurements, meta, _ -> send(test_pid, {:oauth_consent, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    user = ensure_external_id(user)
    insert(:vault, user: user)
    {:ok, token} = Local.issue_access_token(user.external_id, user.email)
    {_verifier, challenge} = pkce_pair()

    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> post("/api/oauth/authorize/consent", authorize_params(client, challenge))
    |> json_response(200)

    assert_received {:oauth_consent, %{count: 1}, %{client: "claude", device: "unknown"}}
    refute_received {:oauth_consent, _, _}
  end

  test "a successful exchange emits mcp_oauth_token_issued for the user", %{
    client: client,
    user: user
  } do
    {verifier, challenge} = pkce_pair()
    json_response(exchange(client, mint_code(client, user, challenge), verifier), 200)

    e = event(drain(), "mcp_oauth_token_issued")
    assert e["distinct_id"] == PostHog.analytics_id(user.email)

    assert Map.take(e["properties"], ~w(grant_type client client_agent auth_method jwks_source)) ==
             %{
               "grant_type" => "authorization_code",
               "client" => "claude",
               "client_agent" => "claude",
               "auth_method" => "none",
               "jwks_source" => "none"
             }
  end

  test "a failed exchange emits mcp_oauth_token_failed, attributed to the code's user", %{
    client: client,
    user: user
  } do
    {_verifier, challenge} = pkce_pair()
    json_response(exchange(client, mint_code(client, user, challenge), "wrong-verifier"), 400)

    e = event(drain(), "mcp_oauth_token_failed")
    assert e["distinct_id"] == PostHog.analytics_id(user.email)

    assert Map.take(e["properties"], ~w(grant_type client error reason)) == %{
             "grant_type" => "authorization_code",
             "client" => "claude",
             "error" => "invalid_grant",
             "reason" => "pkce_mismatch"
           }
  end

  test "a failure with no known user is anonymous", %{client: client} do
    post(build_conn(), "/oauth/token", %{
      "grant_type" => "refresh_token",
      "refresh_token" => "engram_oauth_rt_nope",
      "client_id" => client.client_id
    })

    e = event(drain(), "mcp_oauth_token_failed")
    assert e["properties"]["$process_person_profile"] == false
    assert e["properties"]["reason"] == "refresh_token_unknown"
  end

  test "a grace-window replay emits mcp_oauth_refresh_reuse", %{client: client, user: user} do
    {verifier, challenge} = pkce_pair()

    %{"refresh_token" => rt} =
      json_response(exchange(client, mint_code(client, user, challenge), verifier), 200)

    {:ok, _} = OAuth.rotate_refresh_token(rt, client.client_id)
    {:ok, _} = OAuth.rotate_refresh_token(rt, client.client_id)

    e = event(drain(), "mcp_oauth_refresh_reuse")
    assert e["distinct_id"] == PostHog.analytics_id(user.email)
    assert e["properties"]["within_grace"] == true
    assert e["properties"]["client"] == "claude"
  end

  test "a failed JWKS fetch emits mcp_oauth_jwks_fetch_failed, anonymously" do
    expect(FetcherMock, :fetch, fn _ -> {:error, {:transport_error, :connect, :timeout}} end)

    client = %Client{
      cimd_url: "https://chatgpt.com/oauth/client.json",
      jwks_uri: "https://chatgpt.com/oauth/jwks.json",
      token_endpoint_auth_signing_alg: "RS256"
    }

    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_, private} = JOSE.JWK.to_map(jwk)
    signer = Joken.Signer.create("RS256", private, %{"kid" => "k"})
    {:ok, assertion, _} = Joken.encode_and_sign(%{"iss" => client.cimd_url}, signer)

    assert {:error, :jwks_unavailable} = Jwks.verify_assertion(client, assertion, ["aud"])

    e = event(drain(), "mcp_oauth_jwks_fetch_failed")
    assert e["properties"]["$process_person_profile"] == false

    # Review #11: never the raw host, only the bounded family.
    refute Map.has_key?(e["properties"], "host")

    assert Map.take(e["properties"], ~w(client reason phase result)) == %{
             "client" => "chatgpt",
             "reason" => "connect",
             "phase" => "connect",
             "result" => "error"
           }
  end

  describe "MCP requests" do
    setup %{user: user} do
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      {:ok, _vault, _} = Engram.Vaults.register_vault(user, "V", Ecto.UUID.generate())
      {:ok, api_key, key_row} = Engram.Accounts.create_api_key(user, "k")

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{api_key}")
        |> put_req_header("user-agent", "openai-mcp/1.0.0")

      %{conn: conn, user: user, key_row: key_row}
    end

    # The bug: `mcp_client_connected` fired only from `initialize`, so a client
    # that never sends one on an authenticated request was never counted.
    test "the first authenticated request emits mcp_client_connected, no initialize needed", %{
      conn: conn,
      user: user
    } do
      post(conn, "/api/mcp", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "list_vaults", "arguments" => %{}}
      })

      events = drain()
      connected = event(events, "mcp_client_connected")
      assert connected["distinct_id"] == PostHog.analytics_id(user.email)
      assert connected["properties"]["client"] == "chatgpt"

      assert event(events, "mcp_tool_called")["properties"]["client"] == "chatgpt"
      assert event(events, "mcp_api_key_connected")["properties"]["client"] == "chatgpt"
    end
  end

  # Review #13: the JWKS source lives in the request process, and a
  # keep-alive connection reuses it. A refused assertion must not leave its
  # source behind for the next request to report.
  test "a refused assertion does not leak its jwks_source into the next request", %{
    client: client,
    user: user
  } do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_, public} = JOSE.JWK.to_public_map(jwk)
    jwks_uri = "https://chatgpt.com/oauth/jwks.json"
    cimd_url = "https://chatgpt.com/oauth/client.json"

    expect(FetcherMock, :fetch, fn ^jwks_uri ->
      {:ok, %{"keys" => [Map.put(public, "kid", "k")]}}
    end)

    Engram.Repo.insert!(
      %Client{
        cimd_url: cimd_url,
        cimd_fetched_at: DateTime.utc_now(),
        client_name: "ChatGPT",
        redirect_uris: ["https://chatgpt.com/cb"],
        token_endpoint_auth_method: "private_key_jwt",
        token_endpoint_auth_signing_alg: "RS256",
        jwks_uri: jwks_uri,
        kind: "mcp"
      },
      skip_tenant_check: true
    )

    # Signed by a DIFFERENT key: the JWKS is fetched (source set), then refused.
    {_, wrong} = JOSE.JWK.generate_key({:rsa, 2048}) |> JOSE.JWK.to_map()
    signer = Joken.Signer.create("RS256", wrong, %{"kid" => "k"})
    {:ok, assertion, _} = Joken.encode_and_sign(%{"iss" => cimd_url, "sub" => cimd_url}, signer)

    json_response(
      post(build_conn(), "/oauth/token", %{
        "grant_type" => "refresh_token",
        "refresh_token" => "engram_oauth_rt_x",
        "client_id" => cimd_url,
        "client_assertion" => assertion,
        "client_assertion_type" => Jwks.assertion_type()
      }),
      401
    )

    {verifier, challenge} = pkce_pair()
    json_response(exchange(client, mint_code(client, user, challenge), verifier), 200)

    e = event(drain(), "mcp_oauth_token_issued")
    assert e["properties"]["jwks_source"] == "none"
  end

  test "no code, verifier or token value ever reaches PostHog", %{client: client, user: user} do
    {verifier, challenge} = pkce_pair()
    code = mint_code(client, user, challenge)

    %{"refresh_token" => rt, "access_token" => at} =
      json_response(exchange(client, code, verifier), 200)

    post(build_conn(), "/oauth/token", %{
      "grant_type" => "refresh_token",
      "refresh_token" => rt,
      "client_id" => client.client_id
    })

    json_response(exchange(client, code, verifier), 400)

    wire = drain() |> Jason.encode!()
    assert wire =~ "mcp_oauth_token_issued"

    for secret <- [code, verifier, rt, at] do
      refute wire =~ secret
    end
  end

  # Review of #2061: the code's grant_id lives in the request process too, and
  # a keep-alive connection reuses it. A code exchange that never reached the
  # controller's analytics (here: called directly, as a crashed request would
  # leave it) must not lend its grant_id to the next request's failure.
  test "a stale grant_id does not leak into the next request", %{client: client, user: user} do
    {_verifier, challenge} = pkce_pair()
    code = mint_code(client, user, challenge)

    {:error, _} =
      OAuth.exchange_authorization_code(%{
        "code" => code,
        "redirect_uri" => @redirect,
        "client_id" => client.client_id,
        "code_verifier" => "wrong"
      })

    # No code at all: the exchange never finds one of its own.
    post(build_conn(), "/oauth/token", %{
      "grant_type" => "authorization_code",
      "redirect_uri" => @redirect,
      "client_id" => client.client_id,
      "code_verifier" => "v"
    })
    |> json_response(400)

    e = event(drain(), "mcp_oauth_token_failed")
    assert e["properties"]["reason"] == "code_missing"
    refute Map.has_key?(e["properties"], "grant_id")
  end
end
