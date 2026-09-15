defmodule Engram.OAuth.Cimd.JwksTest do
  # async: false — the JWKS fetch rate limiter's ETS buckets and the JWKS cache
  # table are both node-global, and Mox expectations are set from the test
  # process.
  use Engram.DataCase, async: false

  import Mox

  alias Engram.OAuth.Cimd.FetcherMock
  alias Engram.OAuth.Cimd.Jwks
  alias Engram.OAuth.Cimd.JwksCache
  alias Engram.OAuth.Client

  setup :verify_on_exit!

  setup do
    EngramWeb.RateLimiter.reset_buckets!()
    # The cache is a node-global named table that outlives a test. Without this
    # the second test to use @jwks_uri gets a cache hit, the fetcher is never
    # called, and Mox fails the expectation for a reason that has nothing to do
    # with what the test is asserting.
    JwksCache.clear_local()
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

  defp expect_jwks(public, times \\ 1) do
    expect(FetcherMock, :fetch, times, fn @jwks_uri -> {:ok, %{"keys" => [public]}} end)
  end

  describe "verify_assertion/3" do
    test "accepts an assertion signed by a published key", %{private: private, public: public} do
      expect_jwks(public)

      assert :ok = Jwks.verify_assertion(client(), sign(private, claims()), [@audience])
    end

    # The fix for the review's critical finding. Without a cache the fetch
    # limiter stops being a backstop and becomes a hard ceiling on token
    # exchanges per vendor, and the request that crosses it gets a TERMINAL 401.
    test "fetches the key set once and serves later assertions from cache", %{
      private: private,
      public: public
    } do
      expect_jwks(public, 1)

      for _ <- 1..5 do
        assert :ok = Jwks.verify_assertion(client(), sign(private, claims()), [@audience])
      end
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
      assert {:error, :wrong_audience} = Jwks.verify_assertion(client(), assertion, [@audience])
    end

    test "rejects when iss/sub is not the client", %{private: private, public: public} do
      expect_jwks(public)

      assertion = sign(private, claims(%{"iss" => "https://evil.example/client.json"}))
      assert {:error, :wrong_issuer} = Jwks.verify_assertion(client(), assertion, [@audience])
    end

    test "rejects an expired assertion", %{private: private, public: public} do
      expect_jwks(public)

      past = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.-(60)
      assertion = sign(private, claims(%{"exp" => past}))

      assert {:error, :assertion_expired} =
               Jwks.verify_assertion(client(), assertion, [@audience])
    end

    test "rejects an assertion that is not yet valid", %{private: private, public: public} do
      expect_jwks(public)

      future = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(3600)
      assertion = sign(private, claims(%{"nbf" => future}))

      assert {:error, :assertion_not_yet_valid} =
               Jwks.verify_assertion(client(), assertion, [@audience])
    end

    # A long-lived assertion is a bearer credential sitting in whatever logged
    # it. Its own reason: RFC 7523 sets no maximum, so this bound is OURS, and a
    # vendor minting a legitimate one-hour assertion must not read as a forgery.
    test "rejects an assertion valid for a year", %{private: private, public: public} do
      expect_jwks(public)

      far = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(365 * 24 * 3600)
      assertion = sign(private, claims(%{"exp" => far}))

      assert {:error, :assertion_lifetime_too_long} =
               Jwks.verify_assertion(client(), assertion, [@audience])
    end

    # Vendor clocks drift. A few minutes fast must not read as a policy
    # violation, or we refuse a correct vendor and blame them for it.
    test "tolerates modest clock skew", %{private: private, public: public} do
      expect_jwks(public)

      skewed = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(660)
      assertion = sign(private, claims(%{"exp" => skewed}))

      assert :ok = Jwks.verify_assertion(client(), assertion, [@audience])
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

      assert {:error, :alg_not_allowed} = Jwks.verify_assertion(client(), forged, [@audience])
    end

    # No JWKS expectation: the algorithm is checked before anything is fetched,
    # which is the point — a rejected alg must never cost us an outbound request.
    # Distinct from :alg_not_allowed, because a vendor mid-rotation is not an
    # attacker and the two must not share a log line.
    test "rejects an alg the document did not pin", %{private: private} do
      assertion = sign(private, claims(), "RS512", %{"kid" => @kid})

      assert {:error, :alg_pin_mismatch} = Jwks.verify_assertion(client(), assertion, [@audience])
    end

    # An unknown kid means the vendor rotated, so we refetch once before giving
    # up — waiting out the cache TTL would break every assertion in between.
    test "refetches once on an unknown kid", %{private: private, public: public} do
      expect_jwks(public, 2)

      assertion = sign(private, claims(), "RS256", %{"kid" => "some-other-key"})
      assert {:error, :unknown_kid} = Jwks.verify_assertion(client(), assertion, [@audience])
    end

    test "rejects a signature from a different key", %{public: public} do
      expect_jwks(public)

      {_, other_private} = JOSE.JWK.generate_key({:rsa, 2048}) |> JOSE.JWK.to_map()
      assertion = sign(other_private, claims())

      assert {:error, :bad_signature} = Jwks.verify_assertion(client(), assertion, [@audience])
    end

    # A vendor publishing a key we cannot parse will never self-heal. Reporting
    # it as :bad_signature sends the operator looking for an attacker.
    test "reports an unparseable published key distinctly", %{private: private} do
      expect(FetcherMock, :fetch, fn @jwks_uri ->
        {:ok,
         %{"keys" => [%{"kty" => "RSA", "kid" => @kid, "n" => "!!not-base64!!", "e" => "AQAB"}]}}
      end)

      assert {:error, :unusable_key} =
               Jwks.verify_assertion(client(), sign(private, claims()), [@audience])
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

  describe "transient?/1" do
    # This predicate is what decides 503-and-retry vs a TERMINAL 401. Getting it
    # wrong hands a connector a permanent failure for a condition that clears on
    # its own — the exact misattribution this series is about.
    test "our own transient failures are retryable, the client's are not" do
      assert Jwks.transient?(:jwks_unavailable)
      assert Jwks.transient?(:jwks_rate_limited)

      refute Jwks.transient?(:bad_signature)
      refute Jwks.transient?(:wrong_audience)
      refute Jwks.transient?(:alg_not_allowed)
      refute Jwks.transient?(:assertion_expired)
    end
  end
end
