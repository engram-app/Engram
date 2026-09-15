defmodule Engram.OAuth.Cimd.Jwks do
  @moduledoc """
  Verifies an RFC 7523 `private_key_jwt` client assertion against the keys a
  CIMD client publishes at its own `jwks_uri`.

  ## Why this is safe without a shared secret

  The document that named this `jwks_uri` was itself bound to a host only the
  vendor can serve from (see `Engram.OAuth.Cimd` — the `client_id` field must
  equal the URL it was fetched from). So "whoever controls that host" is exactly
  who we already decided the client is, and the keys inherit that binding. No
  secret has to be minted, transmitted or stored.

  ## The algorithm allowlist is the load-bearing check

  Two classic forgeries live in the JOSE header, and both are free if you trust
  it:

    * `alg: "none"` — the signature is empty and every token verifies.
    * `alg: "HS256"` against a key we fetched as RSA *public* material. The
      public key is, by definition, public; an attacker who can read it can mint
      an HMAC with it. Verifying with an attacker-chosen symmetric algorithm
      turns a public key into a shared secret.

  The header therefore selects a key, never a *kind* of verification: the
  algorithm must be in `@allowed_algs` and must match what the key itself
  declares.

  ## Replay

  Deliberately bounded by a short `exp` window rather than a `jti` store. The
  assertion only authenticates the client on a token request, and the thing it
  guards — the authorization code — is already single-use and PKCE-bound, so a
  replayed assertion buys an attacker nothing they cannot already do with the
  code they would need to steal anyway. A `jti` table would be a new
  write-per-token-request on the hot path for that. Revisit if assertions are
  ever accepted for anything but this exchange.
  """

  alias Engram.OAuth.Cimd.Fetcher
  alias Engram.OAuth.Client
  alias EngramWeb.RateLimiter

  require Logger

  @assertion_type "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"

  # Asymmetric only. See the moduledoc: admitting an HS* algorithm here would
  # let a fetched public key be used as an HMAC secret.
  @allowed_algs ~w(RS256 RS384 RS512 PS256 PS384 PS512 ES256 ES384 ES512)

  # An assertion is minted for one request and presented immediately.
  @max_lifetime_seconds 600

  @window_ms 60_000
  @per_host_limit 10

  @type reason ::
          :no_jwks_uri
          | :malformed_assertion
          | :unsupported_alg
          | :unknown_kid
          | :jwks_unavailable
          | :bad_signature
          | :invalid_claims

  @doc "The RFC 7521 §4.2 `client_assertion_type` we accept."
  def assertion_type, do: @assertion_type

  @doc """
  Verifies `assertion` was signed by `client`, and is addressed to us.

  `audiences` are the values RFC 7523 §3 permits in `aud`: our token endpoint
  URL and our issuer identifier. Checking it is what stops an assertion minted
  for a different authorization server being replayed against this one.
  """
  @spec verify_assertion(Client.t(), String.t(), [String.t()]) :: :ok | {:error, reason()}
  def verify_assertion(%Client{jwks_uri: nil}, _assertion, _audiences), do: {:error, :no_jwks_uri}

  def verify_assertion(%Client{} = client, assertion, audiences) when is_binary(assertion) do
    with {:ok, header} <- peek_header(assertion),
         {:ok, alg} <- allowed_alg(header, client),
         {:ok, keys} <- fetch_keys(client.jwks_uri),
         {:ok, key} <- select_key(keys, header["kid"], alg),
         {:ok, claims} <- verify_signature(assertion, alg, key) do
      validate_claims(claims, client, audiences)
    end
  end

  def verify_assertion(_client, _assertion, _audiences), do: {:error, :malformed_assertion}

  defp peek_header(assertion) do
    case Joken.peek_header(assertion) do
      {:ok, header} when is_map(header) -> {:ok, header}
      _ -> {:error, :malformed_assertion}
    end
  end

  # A document may pin its algorithm. When it does, the header must match it —
  # otherwise the pin is decorative and the client is back to choosing.
  defp allowed_alg(header, client) do
    alg = header["alg"]
    pinned = client.token_endpoint_auth_signing_alg

    cond do
      alg not in @allowed_algs -> {:error, :unsupported_alg}
      is_binary(pinned) and pinned != alg -> {:error, :unsupported_alg}
      true -> {:ok, alg}
    end
  end

  # Reuses the CIMD document seam on purpose: identical SSRF guard, body cap,
  # redirect refusal and JSON content-type check. A second transport here would
  # be a second set of those decisions, free to drift from the one that is
  # tested.
  defp fetch_keys(jwks_uri) do
    with :ok <- rate_limit(jwks_uri),
         {:ok, %{"keys" => keys}} when is_list(keys) <- Fetcher.impl().fetch(jwks_uri) do
      {:ok, keys}
    else
      {:error, :rate_limited} = err -> err
      _ -> {:error, :jwks_unavailable}
    end
  end

  defp rate_limit(jwks_uri) do
    host = URI.parse(jwks_uri).host || "unknown"

    case RateLimiter.hit("cimd:jwks:" <> host, @window_ms, @per_host_limit, :cimd_fetch) do
      {:allow, _} -> :ok
      {:deny, _} -> {:error, :jwks_unavailable}
    end
  end

  # `kid` is a hint, not a credential: it selects which key to try. A document
  # publishing exactly one key may omit it, which is common and harmless.
  defp select_key(keys, kid, alg) do
    usable = Enum.filter(keys, &usable_key?(&1, alg))

    case {kid, usable} do
      {kid, keys} when is_binary(kid) ->
        case Enum.find(keys, &(&1["kid"] == kid)) do
          nil -> {:error, :unknown_kid}
          key -> {:ok, key}
        end

      {nil, [key]} ->
        {:ok, key}

      _ ->
        {:error, :unknown_kid}
    end
  end

  # The key's own `alg`/`use` must not contradict the header. A key published
  # for encryption is not a signing key, and `oct` is symmetric — see moduledoc.
  defp usable_key?(key, alg) when is_map(key) do
    key["kty"] != "oct" and
      key["use"] in [nil, "sig"] and
      key["alg"] in [nil, alg]
  end

  defp usable_key?(_key, _alg), do: false

  defp verify_signature(assertion, alg, key) do
    signer = Joken.Signer.create(alg, key)

    case Joken.verify(assertion, signer) do
      {:ok, claims} -> {:ok, claims}
      {:error, _} -> {:error, :bad_signature}
    end
  rescue
    # A malformed key from a vendor's endpoint must not take the request down.
    _ -> {:error, :bad_signature}
  end

  # RFC 7523 §3: `iss` and `sub` are both the client_id, `aud` is us, `exp` is
  # required. The wire client_id for a CIMD client is its document URL.
  defp validate_claims(claims, client, audiences) do
    now = DateTime.utc_now() |> DateTime.to_unix()
    wire_id = client.cimd_url

    cond do
      claims["iss"] != wire_id -> {:error, :invalid_claims}
      claims["sub"] != wire_id -> {:error, :invalid_claims}
      not audience_match?(claims["aud"], audiences) -> {:error, :invalid_claims}
      not valid_expiry?(claims["exp"], now) -> {:error, :invalid_claims}
      true -> :ok
    end
  end

  # `aud` is a string or an array of strings.
  defp audience_match?(aud, audiences) when is_binary(aud), do: aud in audiences

  defp audience_match?(aud, audiences) when is_list(aud),
    do: Enum.any?(aud, &(&1 in audiences))

  defp audience_match?(_aud, _audiences), do: false

  # Bounded in BOTH directions. An expired assertion is the obvious case; one
  # minted with a year-long `exp` is a bearer credential sitting in whatever
  # logged it, which is the thing the short window exists to prevent.
  defp valid_expiry?(exp, now) when is_integer(exp),
    do: exp > now and exp - now <= @max_lifetime_seconds

  defp valid_expiry?(_exp, _now), do: false
end
