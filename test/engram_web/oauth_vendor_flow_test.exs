defmodule EngramWeb.OAuthVendorFlowTest do
  @moduledoc """
  Replays each real connector's registration through a full OAuth + MCP
  session: authorize, consent, exchange, MCP, refresh, grace replay (#1977).

  Every fixture is copied from a prod `oauth_clients` row (queried 2026-10-15).
  A vendor with no prod row has no fixture, because a guessed shape proves
  nothing about the real client. VS Code, Zed, Gemini CLI and Windsurf are
  absent for that reason; add them when one connects.
  """
  # async: false: Mox stubs, the node-global JWKS cache and the rate limiter.
  use EngramWeb.ConnCase, async: false

  import Mox

  alias Engram.OAuthFlow

  setup :verify_on_exit!

  @kid "vendor-flow-key"

  setup_all do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_, private} = JOSE.JWK.to_map(jwk)
    {_, public} = JOSE.JWK.to_public_map(jwk)
    %{private: private, jwks: %{"keys" => [Map.put(public, "kid", @kid)]}}
  end

  setup do
    EngramWeb.RateLimiter.reset_buckets!()
    Engram.Cache.clear_local(:jwks)

    user = :user |> insert() |> ensure_external_id()
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, _vault, _} = Engram.Vaults.register_vault(user, "V", Ecto.UUID.generate())
    lift_api_rps_cap!(user)
    {:ok, token} = Engram.Auth.Providers.Local.issue_access_token(user.external_id, user.email)

    %{user_token: token, resource: OAuthFlow.discover()["resource"]}
  end

  @dcr_methods ~w(authorization_code refresh_token)

  defp dcr(name, redirect_uris, extra \\ %{}) do
    {:dcr,
     Map.merge(
       %{
         "client_name" => name,
         "redirect_uris" => redirect_uris,
         "grant_types" => @dcr_methods,
         "response_types" => ["code"],
         "token_endpoint_auth_method" => "none"
       },
       extra
     )}
  end

  defp cimd(url, name, redirect_uris, extra \\ %{}) do
    {:cimd,
     Map.merge(
       %{
         "client_id" => url,
         "client_name" => name,
         "redirect_uris" => redirect_uris,
         "grant_types" => @dcr_methods,
         "response_types" => ["code"],
         "token_endpoint_auth_method" => "none"
       },
       extra
     )}
  end

  @chatgpt_url "https://chatgpt.com/oauth/ig2N09X8ZQ6D/client.json"
  @chatgpt_redirect "https://chatgpt.com/connector/oauth/ig2N09X8ZQ6D"

  defp chatgpt_cimd do
    cimd(@chatgpt_url, "ChatGPT", [@chatgpt_redirect], %{
      "token_endpoint_auth_method" => "private_key_jwt",
      "token_endpoint_auth_methods_supported" => ["none", "private_key_jwt"],
      "token_endpoint_auth_signing_alg" => "RS256",
      "jwks_uri" => "https://chatgpt.com/oauth/jwks.json"
    })
  end

  # name, registration, runtime redirect_uri, extra authorize params
  defp public_vendors do
    [
      {"ChatGPT (DCR)", dcr("ChatGPT", [@chatgpt_redirect]), @chatgpt_redirect, %{}},
      {"Codex (CIMD, loopback runtime port)",
       cimd("https://chatgpt.com/oauth/codex/vlXsL-r9MIRD/client.json", "Codex", [
         "http://127.0.0.1/callback/vlXsL-r9MIRD",
         "http://localhost/callback/vlXsL-r9MIRD"
       ]), "http://127.0.0.1:55578/callback/vlXsL-r9MIRD", %{}},
      {"Codex (DCR)",
       dcr("Codex", ["http://127.0.0.1:55578/callback/vlXsL-r9MIRD"], %{"scope" => "mcp"}),
       "http://127.0.0.1:55578/callback/vlXsL-r9MIRD", %{"scope" => "mcp"}},
      {"Claude.ai (CIMD)",
       cimd("https://claude.ai/oauth/mcp-oauth-client-metadata", "Claude", [
         "https://claude.ai/api/mcp/auth_callback"
       ]), "https://claude.ai/api/mcp/auth_callback", %{}},
      {"Claude.ai (DCR)",
       dcr("Claude", ["https://claude.ai/api/mcp/auth_callback"], %{"scope" => "mcp"}),
       "https://claude.ai/api/mcp/auth_callback", %{"scope" => "mcp"}},
      {"Claude Code (CIMD, loopback runtime port)",
       cimd("https://claude.ai/oauth/claude-code-client-metadata", "Claude Code", [
         "http://localhost/callback",
         "http://127.0.0.1/callback"
       ]), "http://localhost:62279/callback", %{}},
      {"Claude Code (DCR)", dcr("Claude Code (engram)", ["http://localhost:3118/callback"]),
       "http://localhost:3118/callback", %{}},
      {"Cursor (DCR, custom scheme)",
       dcr("Cursor", [
         "cursor://anysphere.cursor-mcp/oauth/callback",
         "https://www.cursor.com/agents/mcp/oauth/callback",
         "http://localhost:8787/callback"
       ]), "cursor://anysphere.cursor-mcp/oauth/callback", %{}},
      {"OpenCode (CIMD)",
       cimd("https://opencode.ai/oauth/opencode/client.json", "opencode", [
         "http://127.0.0.1/callback",
         "http://localhost/callback"
       ]), "http://127.0.0.1:19876/callback", %{}},
      {"Google Antigravity (CIMD)",
       cimd("https://antigravity.google/oauth/client-metadata.json", "Google Antigravity", [
         "https://antigravity.google/oauth-callback"
       ]), "https://antigravity.google/oauth-callback", %{}},
      {"Grok (DCR, trailing slash)",
       dcr("Grok", ["https://grok.com/connectors-oauth-exchange-code/"]),
       "https://grok.com/connectors-oauth-exchange-code/", %{}},
      {"Mistral (DCR)",
       dcr(
         "mistral-mcp-client",
         ["https://callback.mistral.ai/v1/integrations_auth/oauth2_callback"],
         %{"scope" => "mcp"}
       ), "https://callback.mistral.ai/v1/integrations_auth/oauth2_callback", %{"scope" => "mcp"}}
    ]
  end

  # The whole session a connector depends on, and the refresh that #1974 lost.
  defp full_session(vendor, ctx, jwks \\ nil) do
    vendor =
      Map.update(
        vendor,
        :authorize,
        %{"resource" => ctx.resource},
        &Map.put(&1, "resource", ctx.resource)
      )

    client_id = OAuthFlow.register(vendor, jwks)

    tokens =
      OAuthFlow.exchange(
        vendor,
        client_id,
        OAuthFlow.authorize(vendor, client_id, ctx.user_token)
      )

    :ok = OAuthFlow.mcp_session(tokens["access_token"])

    rotated =
      vendor |> OAuthFlow.refresh(client_id, tokens["refresh_token"]) |> json_response(200)

    refute rotated["refresh_token"] == tokens["refresh_token"]
    :ok = OAuthFlow.mcp_session(rotated["access_token"])

    # A client that timed out on the rotation retries with the old token. Inside
    # the grace window that must succeed, or the connector is dead until re-auth.
    replay = vendor |> OAuthFlow.refresh(client_id, tokens["refresh_token"]) |> json_response(200)
    :ok = OAuthFlow.mcp_session(replay["access_token"])

    # Disconnect in the client. The chain is dead afterwards.
    assert OAuthFlow.revoke(vendor, client_id, replay["refresh_token"]).status == 200

    assert vendor
           |> OAuthFlow.refresh(client_id, replay["refresh_token"])
           |> json_response(400)
           |> Map.fetch!("error") == "invalid_grant"
  end

  describe "public clients (none + PKCE)" do
    test "every recorded vendor completes a session", ctx do
      for {name, registration, redirect_uri, authorize} <- public_vendors() do
        EngramWeb.RateLimiter.reset_buckets!()

        vendor = %{
          name: name,
          registration: registration,
          redirect_uri: redirect_uri,
          auth: :none,
          authorize: authorize
        }

        try do
          full_session(vendor, ctx)
        rescue
          e in ExUnit.AssertionError ->
            reraise %{e | message: "#{name}: #{e.message}"}, __STACKTRACE__
        end
      end
    end
  end

  describe "ChatGPT connector (CIMD)" do
    test "private_key_jwt: exchange and refresh with signed assertions", ctx do
      vendor = %{
        registration: chatgpt_cimd(),
        redirect_uri: @chatgpt_redirect,
        auth: {:private_key_jwt, ctx.private, @kid}
      }

      full_session(vendor, ctx, ctx.jwks)
    end

    # ChatGPT declares private_key_jwt and then exchanges as a public client.
    test "none fallback: the same document, exchanged without an assertion", ctx do
      vendor = %{registration: chatgpt_cimd(), redirect_uri: @chatgpt_redirect, auth: :none}
      full_session(vendor, ctx)
    end
  end
end
