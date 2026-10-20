defmodule Engram.OAuthCodeExpiredTest do
  @moduledoc """
  A minted code the client never exchanged is the direct "handoff broke"
  signal (#2003: the consent tab never redirected on mobile). The hourly
  cleanup that deletes expired codes counts each unredeemed one, by client
  family and the consent browser's device, as
  `engram_prom_ex_oauth_code_expired_total` and `mcp_oauth_code_expired`.
  Global app env (PostHog), so not async.
  """
  use Engram.DataCase, async: false

  import Engram.OAuthHelpers, only: [code_from_redirect: 1, pkce_pair: 0]

  alias Engram.OAuth
  alias Engram.OAuth.AuthorizationCode

  @redirect "https://claude.ai/api/mcp/auth_callback"

  setup do
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

    handler = "oauth-code-expired-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:engram, :oauth, :code_expired],
      fn _e, m, meta, _ -> send(parent, {:code_expired, m, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, client} =
      OAuth.register_client(%{"redirect_uris" => [@redirect], "client_name" => "Claude"})

    %{client: client, user: insert(:user)}
  end

  defp mint(user, client, device) do
    {verifier, challenge} = pkce_pair()

    {:ok, validated} =
      OAuth.validate_authorization_request(%{
        "client_id" => client.client_id,
        "redirect_uri" => @redirect,
        "response_type" => "code",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "state" => "s",
        "scope" => "mcp"
      })

    {:ok, url, _granted, grant_id} =
      OAuth.mint_authorization_code_granted(user, Map.put(validated, :device, device), :all, nil)

    {code_from_redirect(url), verifier, grant_id}
  end

  defp age_all_codes do
    past = DateTime.utc_now(:second) |> DateTime.add(-2 * 3600, :second)
    Repo.update_all(AuthorizationCode, [set: [expires_at: past]], skip_tenant_check: true)
  end

  defp drain(acc \\ []) do
    receive do
      {:posthog_body, b} -> drain([b | acc])
    after
      400 -> acc
    end
  end

  test "an unredeemed code is counted once when it is reaped", %{client: client, user: user} do
    {_code, _verifier, grant_id} = mint(user, client, "mobile")
    age_all_codes()

    OAuth.cleanup_expired()

    assert_received {:code_expired, %{count: 1}, %{client: "claude", device: "mobile"}}
    refute_received {:code_expired, _, _}

    e = Enum.find(drain(), &(&1["event"] == "mcp_oauth_code_expired"))
    assert e["properties"]["client"] == "claude"
    assert e["properties"]["device"] == "mobile"
    assert e["properties"]["grant_id"] == grant_id

    # Reaped: a second sweep counts nothing.
    OAuth.cleanup_expired()
    refute_received {:code_expired, _, _}
  end

  test "a redeemed code is not counted", %{client: client, user: user} do
    {code, verifier, _} = mint(user, client, "desktop")

    {:ok, _} =
      OAuth.exchange_authorization_code(%{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => @redirect,
        "client_id" => client.client_id,
        "code_verifier" => verifier
      })

    age_all_codes()
    OAuth.cleanup_expired()

    refute_received {:code_expired, _, _}
  end

  test "a code minted before the device was stored counts as unknown", %{
    client: client,
    user: user
  } do
    mint(user, client, nil)
    age_all_codes()
    OAuth.cleanup_expired()

    assert_received {:code_expired, _, %{client: "claude", device: "unknown"}}
  end
end
