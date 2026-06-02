defmodule Engram.ClerkHelpers do
  @moduledoc """
  Test helpers for Clerk JWT authentication.

  Generates an RSA keypair at compile time, provides functions to:
  - Build a JWKS JSON document from the public key
  - Sign test JWTs that ClerkToken will accept
  - Start a Bypass server serving the JWKS endpoint
  """

  @kid "test-clerk-key-1"
  @issuer "https://test-clerk.example.com"

  # Generate RSA keypair at compile time (once per test suite run)
  @jwk JOSE.JWK.generate_key({:rsa, 2048})
  @public_jwk JOSE.JWK.to_public(@jwk)

  def kid, do: @kid
  def issuer, do: @issuer

  @doc "Returns the JWKS JSON string containing the test public key."
  def jwks_json do
    {_kty, public_map} = JOSE.JWK.to_map(@public_jwk)

    keys = [Map.merge(public_map, %{"kid" => @kid, "use" => "sig", "alg" => "RS256"})]

    Jason.encode!(%{"keys" => keys})
  end

  @doc "Signs a JWT with the test RSA private key and returns the compact token string."
  def sign_clerk_jwt(claims) do
    jws = %{"alg" => "RS256", "kid" => @kid}

    {_alg, token} =
      JOSE.JWK.sign(Jason.encode!(claims), jws, @jwk)
      |> JOSE.JWS.compact()

    token
  end

  @doc "Builds a valid set of Clerk JWT claims for the given clerk_user_id."
  def clerk_claims(clerk_user_id, opts \\ []) do
    now = :os.system_time(:second)

    base = %{
      "sub" => clerk_user_id,
      "iss" => Keyword.get(opts, :issuer, @issuer),
      "iat" => now - 10,
      "exp" => Keyword.get(opts, :exp, now + 3600),
      "nbf" => now - 10,
      "email" => Keyword.get(opts, :email, "clerk-user@example.com")
    }

    case Keyword.fetch(opts, :azp) do
      {:ok, azp} -> Map.put(base, "azp", azp)
      :error -> base
    end
  end

  @doc """
  Starts a Bypass server that serves the test JWKS at /.well-known/jwks.json.
  Returns the bypass and the JWKS URL.
  """
  def start_jwks_server do
    bypass = Bypass.open()

    Bypass.expect(bypass, "GET", "/.well-known/jwks.json", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, jwks_json())
    end)

    jwks_url = "http://localhost:#{bypass.port}/.well-known/jwks.json"
    {bypass, jwks_url}
  end
end
