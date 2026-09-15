defmodule Engram.OAuth.Cimd.JwksTest do
  # async: false — the JWKS fetch rate limiter's ETS buckets are node-global and
  # Mox expectations are set from the test process.
  use Engram.DataCase, async: false

  import Mox

  alias Engram.OAuth.Cimd.FetcherMock
  alias Engram.OAuth.Cimd.Jwks
  alias Engram.OAuth.Client

  setup :verify_on_exit!

  setup do
    EngramWeb.RateLimiter.reset_buckets!()
    :ok
  end

  @client_url "https://chatgpt.com/oauth/client.json"
  @jwks_uri "https://chatgpt.com/oauth/jwks.json"
  @audience "https://mcp.engram.page/oauth/token"
  @kid "test-key-1"

  # One keypair for the whole module: generating RSA is slow enough that doing it
  # per test dominates the runtime, and none of these tests care about key reuse.
  setup_all do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_, private_map} = JOSE.JWK.to_map(jwk)
    {_, public_map} = JOSE.JWK.to_public_map(jwk)

    %{private: private_map, public: Map.put(public_map, "kid", @kid)}
  end

  defp client(overrides \\ %{}) do
    Map.merge(
      %Client{
        cimd_url: @client_url,
        jwks_uri: @jwks_uri,
        token_endpoint_auth_method: "private_key_jwt",
        token_endpoint_auth_signing_alg: "RS256"
      },
      overrides
    )
  end

  defp claims(overrides \\ %{}) do
    now = DateTime.utc_now() |> DateTime.to_unix()

    Map.merge(
      %{
        "iss" => @client_url,
        "sub" => @client_url,
        "aud" => @audience,
        "exp" => now + 300,
        "iat" => now
      },
      overrides
    )
  end

  defp sign(private, claims, alg \\ "RS256", headers \\ %{"kid" => @kid}) do
    signer = Joken.Signer.create(alg, private, headers)
    {:ok, token, _} = Joken.encode_and_sign(claims, signer)
    token
  end

  defp expect_jwks(public) do
    expect(FetcherMock, :fetch, fn @jwks_uri -> {:ok, %{"keys" => [public]}} end)
  end

  describe "verify_assertion/3" do
    test "accepts an assertion signed by a published key", %{private: private, public: public} do
      expect_jwks(public)

      assert :ok = Jwks.verify_assertion(client(), sign(private, claims()), [@audience])
    end

    test "accepts when aud is an array containing us", %{private: private, public: public} do
      expect_jwks(public)

      assertion = sign(private, claims(%{"aud" => ["https://elsewhere", @audience]}))
      assert :ok = Jwks.verify_assertion(client(), assertion, [@audience])
    end

    # The whole point of checking `aud`: an assertion minted for another
    # authorization server must not be replayable against this one.
    test "rejects an assertion addressed elsewhere", %{private: private, public: public} do
      expect_jwks(public)

      assertion = sign(private, claims(%{"aud" => "https://someone-else/oauth/token"}))
      assert {:error, :invalid_claims} = Jwks.verify_assertion(client(), assertion, [@audience])
    end

    test "rejects when iss/sub is not the client", %{private: private, public: public} do
      expect_jwks(public)

      assertion = sign(private, claims(%{"iss" => "https://evil.example/client.json"}))
      assert {:error, :invalid_claims} = Jwks.verify_assertion(client(), assertion, [@audience])
    end

    test "rejects an expired assertion", %{private: private, public: public} do
      expect_jwks(public)

      past = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.-(60)
      assertion = sign(private, claims(%{"exp" => past}))
      assert {:error, :invalid_claims} = Jwks.verify_assertion(client(), assertion, [@audience])
    end

    # A long-lived assertion is a bearer credential sitting in whatever logged it.
    test "rejects an assertion valid for a year", %{private: private, public: public} do
      expect_jwks(public)

      far = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(365 * 24 * 3600)
      assertion = sign(private, claims(%{"exp" => far}))
      assert {:error, :invalid_claims} = Jwks.verify_assertion(client(), assertion, [@audience])
    end

    # THE forgery this module exists to refuse. The RSA public key is public by
    # definition, so anyone who can read the JWKS could mint an HMAC with it.
    # Verification must never take its algorithm from the attacker's header.
    test "rejects an HS256 assertion forged with the public key", %{public: public} do
      forged =
        Joken.Signer.create("HS256", Jason.encode!(public))
        |> then(fn signer ->
          {:ok, token, _} = Joken.encode_and_sign(claims(), signer)
          token
        end)

      assert {:error, :unsupported_alg} =
               Jwks.verify_assertion(client(), forged, [@audience])
    end

    # No JWKS expectation: the algorithm is checked before anything is fetched,
    # which is the point — a rejected alg must never cost us an outbound request.
    test "rejects an alg the document did not pin", %{private: private} do
      assertion = sign(private, claims(), "RS512", %{"kid" => @kid})

      assert {:error, :unsupported_alg} =
               Jwks.verify_assertion(client(), assertion, [@audience])
    end

    test "rejects an unknown kid", %{private: private, public: public} do
      expect_jwks(public)

      assertion = sign(private, claims(), "RS256", %{"kid" => "some-other-key"})
      assert {:error, :unknown_kid} = Jwks.verify_assertion(client(), assertion, [@audience])
    end

    test "rejects a signature from a different key", %{public: public} do
      expect_jwks(public)

      {_, other_private} = JOSE.JWK.generate_key({:rsa, 2048}) |> JOSE.JWK.to_map()
      assertion = sign(other_private, claims())

      assert {:error, :bad_signature} = Jwks.verify_assertion(client(), assertion, [@audience])
    end

    test "refuses a client with no published keys", %{private: private} do
      assertion = sign(private, claims())

      assert {:error, :no_jwks_uri} =
               Jwks.verify_assertion(client(%{jwks_uri: nil}), assertion, [@audience])
    end

    test "refuses garbage" do
      assert {:error, :malformed_assertion} =
               Jwks.verify_assertion(client(), "not-a-jwt", [@audience])
    end

    test "surfaces an unreachable JWKS endpoint as unavailable", %{private: private} do
      expect(FetcherMock, :fetch, fn @jwks_uri -> {:error, :fetch_failed} end)

      assert {:error, :jwks_unavailable} =
               Jwks.verify_assertion(client(), sign(private, claims()), [@audience])
    end
  end
end
