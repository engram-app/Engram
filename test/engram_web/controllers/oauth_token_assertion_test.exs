defmodule EngramWeb.OAuthTokenAssertionTest do
  @moduledoc """
  End-to-end coverage of `private_key_jwt` at `POST /oauth/token`.

  `jwks_test.exs` covers the crypto; this covers the WIRING, which had none.
  Given this series' own thesis — a suite that only exercises what already works
  cannot report what does not — an untested credential path was the conspicuous
  gap. The rejection branches matter most: each one 401s before
  `authenticate_client/3` is ever reached, so a vendor sending a slightly-wrong
  `client_assertion_type` fails forever, and only a test holds that shut.
  """
  # async: false — Mox expectations plus the node-global JWKS cache and limiter.
  use EngramWeb.ConnCase, async: false

  import Mox

  alias Engram.OAuth
  alias Engram.OAuth.Cimd.FetcherMock
  alias Engram.OAuth.Cimd.Jwks
  alias Engram.OAuth.Cimd.JwksCache
  alias Engram.OAuth.Client
  alias Engram.Repo

  setup :verify_on_exit!

  setup do
    EngramWeb.RateLimiter.reset_buckets!()
    JwksCache.clear_local()
    :ok
  end

  @client_url "https://chatgpt.com/oauth/client.json"
  @jwks_uri "https://chatgpt.com/oauth/jwks.json"
  @redirect_uri "https://chatgpt.com/connector_platform_oauth_redirect"
  @kid "assertion-test-key"

  setup_all do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_, private_map} = JOSE.JWK.to_map(jwk)
    {_, public_map} = JOSE.JWK.to_public_map(jwk)

    %{private: private_map, public: Map.put(public_map, "kid", @kid)}
  end

  # Inserted directly with a fresh `cimd_fetched_at`, so `Cimd.ensure_client/1`
  # serves it from the row and the authorize step performs no document fetch.
  defp cimd_client do
    Repo.insert!(
      %Client{
        cimd_url: @client_url,
        cimd_fetched_at: DateTime.utc_now(),
        client_name: "ChatGPT",
        redirect_uris: [@redirect_uri],
        grant_types: ["authorization_code", "refresh_token"],
        response_types: ["code"],
        token_endpoint_auth_method: "private_key_jwt",
        token_endpoint_auth_signing_alg: "RS256",
        jwks_uri: @jwks_uri,
        kind: "mcp"
      },
      skip_tenant_check: true
    )
  end

  defp pkce_pair do
    verifier = :crypto.strong_rand_bytes(48) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  defp mint_code(user, challenge) do
    {:ok, validated} =
      OAuth.validate_authorization_request(%{
        "client_id" => @client_url,
        "redirect_uri" => @redirect_uri,
        "response_type" => "code",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "scope" => "mcp"
      })

    {:ok, redirect_url} = OAuth.mint_authorization_code(user, validated, :all, nil)
    %{query: query} = URI.parse(redirect_url)
    URI.decode_query(query)["code"]
  end

  defp assertion(private, overrides \\ %{}) do
    now = DateTime.utc_now() |> DateTime.to_unix()

    claims =
      Map.merge(
        %{
          "iss" => @client_url,
          "sub" => @client_url,
          "aud" => EngramWeb.Endpoint.url() <> "/oauth/token",
          "exp" => now + 300,
          "iat" => now
        },
        overrides
      )

    signer = Joken.Signer.create("RS256", private, %{"kid" => @kid})
    {:ok, token, _} = Joken.encode_and_sign(claims, signer)
    token
  end

  defp exchange_params(code, verifier, extra) do
    Map.merge(
      %{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => @redirect_uri,
        "code_verifier" => verifier
      },
      extra
    )
  end

  describe "POST /oauth/token with a client assertion" do
    test "exchanges a code when the assertion verifies", %{
      conn: conn,
      private: private,
      public: public
    } do
      expect(FetcherMock, :fetch, fn @jwks_uri -> {:ok, %{"keys" => [public]}} end)

      user = insert(:user)
      cimd_client()
      {verifier, challenge} = pkce_pair()
      code = mint_code(user, challenge)

      params =
        exchange_params(code, verifier, %{
          "client_id" => @client_url,
          "client_assertion" => assertion(private),
          "client_assertion_type" => Jwks.assertion_type()
        })

      body = conn |> post("/oauth/token", params) |> json_response(200)

      assert is_binary(body["access_token"])
      assert is_binary(body["refresh_token"])
      assert body["token_type"] == "Bearer"
    end

    # RFC 7521 §4.2: the assertion carries the client's identity, so client_id
    # is optional beside it. A vendor omitting it must still work.
    test "derives the client from the assertion when client_id is absent", %{
      conn: conn,
      private: private,
      public: public
    } do
      expect(FetcherMock, :fetch, fn @jwks_uri -> {:ok, %{"keys" => [public]}} end)

      user = insert(:user)
      cimd_client()
      {verifier, challenge} = pkce_pair()
      code = mint_code(user, challenge)

      params =
        exchange_params(code, verifier, %{
          "client_assertion" => assertion(private),
          "client_assertion_type" => Jwks.assertion_type()
        })

      assert %{"access_token" => _} = conn |> post("/oauth/token", params) |> json_response(200)
    end

    # The unit test pins that `Jwks` accepts the issuer form; this pins that the
    # controller actually OFFERS it. `auth_opts/2` builds both audiences from
    # `OAuthMetadata.base_url/1`, which is the same value discovery advertises as
    # `issuer` — so a vendor that reads discovery and addresses the issuer must
    # work. Only an end-to-end exchange proves the two halves agree.
    test "exchanges a code when aud is the issuer rather than the token endpoint", %{
      conn: conn,
      private: private,
      public: public
    } do
      expect(FetcherMock, :fetch, fn @jwks_uri -> {:ok, %{"keys" => [public]}} end)

      user = insert(:user)
      cimd_client()
      {verifier, challenge} = pkce_pair()
      code = mint_code(user, challenge)

      params =
        exchange_params(code, verifier, %{
          "client_id" => @client_url,
          "client_assertion" => assertion(private, %{"aud" => EngramWeb.Endpoint.url()}),
          "client_assertion_type" => Jwks.assertion_type()
        })

      assert %{"access_token" => _} = conn |> post("/oauth/token", params) |> json_response(200)
    end

    # The highest-probability real interop failure in this path: a vendor sends a
    # draft-era or whitespace-padded URN. Before this it 401'd forever and logged
    # nothing anywhere.
    test "refuses an unrecognised client_assertion_type", %{conn: conn, private: private} do
      user = insert(:user)
      cimd_client()
      {verifier, challenge} = pkce_pair()
      code = mint_code(user, challenge)

      params =
        exchange_params(code, verifier, %{
          "client_id" => @client_url,
          "client_assertion" => assertion(private),
          "client_assertion_type" => "urn:ietf:params:oauth:client-assertion-type:jwt-bearer "
        })

      body = conn |> post("/oauth/token", params) |> json_response(401)
      assert body["error"] == "invalid_client"
    end

    test "refuses an assertion presented alongside a client_secret", %{
      conn: conn,
      private: private
    } do
      user = insert(:user)
      cimd_client()
      {verifier, challenge} = pkce_pair()
      code = mint_code(user, challenge)

      params =
        exchange_params(code, verifier, %{
          "client_id" => @client_url,
          "client_secret" => "not-a-thing",
          "client_assertion" => assertion(private),
          "client_assertion_type" => Jwks.assertion_type()
        })

      assert %{"error" => "invalid_client"} =
               conn |> post("/oauth/token", params) |> json_response(401)
    end

    test "refuses an assertion presented alongside HTTP Basic", %{conn: conn, private: private} do
      user = insert(:user)
      cimd_client()
      {verifier, challenge} = pkce_pair()
      code = mint_code(user, challenge)

      params =
        exchange_params(code, verifier, %{
          "client_assertion" => assertion(private),
          "client_assertion_type" => Jwks.assertion_type()
        })

      body =
        conn
        |> put_req_header(
          "authorization",
          Plug.BasicAuth.encode_basic_auth(@client_url, "s3cret")
        )
        |> post("/oauth/token", params)
        |> json_response(401)

      assert body["error"] == "invalid_client"
    end

    test "refuses a private_key_jwt client presenting no assertion at all", %{conn: conn} do
      user = insert(:user)
      cimd_client()
      {verifier, challenge} = pkce_pair()
      code = mint_code(user, challenge)

      params = exchange_params(code, verifier, %{"client_id" => @client_url})

      assert %{"error" => "invalid_client"} =
               conn |> post("/oauth/token", params) |> json_response(401)
    end

    # THE distinction the review called critical. `invalid_client` is terminal
    # per RFC 6749 §5.2 — the connector stops and the user sees a permanently
    # dead integration. An unreachable JWKS endpoint is ours and clears on its
    # own, so it must come back retryable or we turn a blip into a dead vendor.
    test "reports an unreachable JWKS endpoint as retryable, not terminal", %{
      conn: conn,
      private: private
    } do
      expect(FetcherMock, :fetch, fn @jwks_uri -> {:error, :fetch_failed} end)

      user = insert(:user)
      cimd_client()
      {verifier, challenge} = pkce_pair()
      code = mint_code(user, challenge)

      params =
        exchange_params(code, verifier, %{
          "client_id" => @client_url,
          "client_assertion" => assertion(private),
          "client_assertion_type" => Jwks.assertion_type()
        })

      body = conn |> post("/oauth/token", params) |> json_response(503)
      assert body["error"] == "temporarily_unavailable"
    end
  end
end
