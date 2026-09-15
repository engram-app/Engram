defmodule Engram.OAuth.Cimd.Jwks do
  @moduledoc """
  Verifies an RFC 7523 `private_key_jwt` client assertion against the keys a
  CIMD client publishes at its own `jwks_uri`.

  ## Why this is safe without a shared secret

  The document that named this `jwks_uri` was itself bound to a host only the
  vendor can serve from (see `Engram.OAuth.Cimd` — the `client_id` field must
  equal the URL it was fetched from). So "whoever controls that host" is exactly
  who we already decided the client is. No secret has to be minted, transmitted
  or stored.

  That binding covers the *document*. It does not automatically cover the keys:
  a document may name a `jwks_uri` on a different origin, which turns a host
  binding into a delegation. `Engram.OAuth.Cimd` therefore refuses a cross-origin
  `jwks_uri` at document-validation time, where the refusal is legible, rather
  than letting it surface as a mystery 401 per token request.

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
  declares. It is checked BEFORE any fetch, so a rejected alg costs no outbound
  request.

  ## Every refusal gets its own reason

  Deliberate, and the whole reason this module exists. `private_key_jwt` was
  refused outright for weeks and nobody could tell, because the failure was a
  bare 401 with no attributable log line. A reason that says
  `:assertion_lifetime_too_long` (our policy) rather than `:invalid_claims`
  (the vendor's bug) is the difference between a five-minute fix and another
  week. `Engram.OAuth` maps the transient ones to a retryable 503 rather than a
  terminal 401.

  ## Replay

  Bounded by a short `exp` window rather than a `jti` store. The assertion only
  authenticates the client on a token request, and the thing it guards — the
  authorization code — is already single-use and PKCE-bound, so a replayed
  assertion buys an attacker nothing they cannot already do with the code they
  would need to steal anyway. A `jti` table would be a new write-per-token-request
  on the hot path for that. Revisit if assertions are ever accepted for anything
  but this exchange.
  """

  alias Engram.OAuth.Cimd.JwksCache
  alias Engram.OAuth.Client

  require Logger

  @assertion_type "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"

  # Asymmetric only. See the moduledoc: admitting an HS* algorithm here would
  # let a fetched public key be used as an HMAC secret.
  @allowed_algs ~w(RS256 RS384 RS512 PS256 PS384 PS512 ES256 ES384 ES512)

  # An assertion is minted for one request and presented immediately. RFC 7523
  # sets no maximum, so this bound is OURS — hence its own reason atom, because
  # a vendor minting a legitimate one-hour assertion is not a forgery and must
  # not read like one in the logs.
  @max_lifetime_seconds 600

  # Vendor clocks drift. Without leeway a vendor running a few minutes fast has
  # every assertion refused for being too long-lived, which looks exactly like
  # a policy violation and is not.
  @clock_skew_seconds 120

  @type reason ::
          :no_jwks_uri
          | :malformed_assertion
          | :alg_not_allowed
          | :alg_pin_mismatch
          | :no_usable_key
          | :ambiguous_key
          | :unknown_kid
          | :unusable_key
          | :jwks_unavailable
          | :jwks_rate_limited
          | :bad_signature
          | :wrong_issuer
          | :wrong_audience
          | :assertion_expired
          | :assertion_not_yet_valid
          | :assertion_lifetime_too_long

  # Our side of the wire, and clears on its own. `Engram.OAuth` turns these into
  # a retryable 503 instead of a terminal `invalid_client`.
  @transient_reasons ~w(jwks_unavailable jwks_rate_limited)a

  @doc "The RFC 7521 §4.2 `client_assertion_type` we accept."
  def assertion_type, do: @assertion_type

  @doc "True when a refusal is ours and transient rather than the client's fault."
  @spec transient?(reason()) :: boolean()
  def transient?(reason), do: reason in @transient_reasons

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
         {:ok, key} <- resolve_key(client.jwks_uri, header["kid"], alg),
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

  # Two very different conditions, deliberately NOT sharing an atom. An alg
  # outside the allowlist is the forgery this module exists to stop. An alg that
  # merely disagrees with the document's pin is a vendor mid-rotation, and the
  # pin only refreshes on the authorize path — so it is an availability problem
  # with a 24h fuse, not an attack.
  defp allowed_alg(header, client) do
    alg = header["alg"]
    pinned = client.token_endpoint_auth_signing_alg

    cond do
      alg not in @allowed_algs -> {:error, :alg_not_allowed}
      is_binary(pinned) and pinned != alg -> {:error, :alg_pin_mismatch}
      true -> {:ok, alg}
    end
  end

  # An unknown `kid` means the vendor rotated. Waiting out the cache TTL would
  # break every assertion in between, so refetch once, bounded by its own
  # bucket. Any other failure is returned as-is rather than retried — refetching
  # cannot conjure a key that was filtered for being unusable.
  defp resolve_key(jwks_uri, kid, alg) do
    with {:ok, keys} <- JwksCache.keys(jwks_uri),
         {:error, :unknown_kid} <- select_key(keys, kid, alg) do
      case JwksCache.refresh(jwks_uri) do
        {:ok, refreshed} -> select_key(refreshed, kid, alg)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # `kid` is a hint, not a credential: it selects which key to try. A document
  # publishing exactly one key may omit it, which is common and harmless. Two
  # usable keys and no kid is a vendor mid-rotation publishing old and new at
  # once — a distinct, benign, and entirely different problem from "we hold no
  # key that could work", so they do not share an atom.
  defp select_key(keys, kid, alg) do
    usable = Enum.filter(keys, &usable_key?(&1, alg))

    case {kid, usable} do
      {kid, candidates} when is_binary(kid) ->
        case Enum.find(candidates, &(&1["kid"] == kid)) do
          nil -> {:error, :unknown_kid}
          key -> {:ok, key}
        end

      {nil, [key]} ->
        {:ok, key}

      {nil, []} ->
        {:error, :no_usable_key}

      {nil, _many} ->
        {:error, :ambiguous_key}
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

  # `Joken.Signer.create/2` raises on a key it cannot parse — a truncated or
  # standard-base64 `n`, a missing `kty`, an alg/key-family mismatch. That is a
  # vendor publishing something broken, which will never self-heal, and it must
  # NOT be reported as `:bad_signature` — the reason that usually means someone
  # is probing us. Only the construction is guarded; `Joken.verify/2` already
  # returns `{:error, _}` rather than raising, so wrapping it too would only
  # hide our own future bugs in here.
  defp verify_signature(assertion, alg, key) do
    case build_signer(alg, key) do
      {:ok, signer} ->
        case Joken.verify(assertion, signer) do
          {:ok, claims} -> {:ok, claims}
          {:error, _} -> {:error, :bad_signature}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_signer(alg, key) do
    {:ok, Joken.Signer.create(alg, key)}
  rescue
    _ -> {:error, :unusable_key}
  end

  # RFC 7523 §3: `iss` and `sub` are both the client_id, `aud` is us, `exp` is
  # required. The wire client_id for a CIMD client is its document URL.
  #
  # One condition per reason. Collapsing these is what turns "ChatGPT is
  # addressing our staging audience" and "their clock is skewed" into the same
  # unactionable log line.
  defp validate_claims(claims, client, audiences) do
    now = DateTime.utc_now() |> DateTime.to_unix()
    wire_id = client.cimd_url

    cond do
      claims["iss"] != wire_id -> {:error, :wrong_issuer}
      claims["sub"] != wire_id -> {:error, :wrong_issuer}
      not audience_match?(claims["aud"], audiences) -> {:error, :wrong_audience}
      not_yet_valid?(claims["nbf"], now) -> {:error, :assertion_not_yet_valid}
      true -> validate_expiry(claims["exp"], now)
    end
  end

  # `aud` is a string or an array of strings.
  defp audience_match?(aud, audiences) when is_binary(aud), do: aud in audiences

  defp audience_match?(aud, audiences) when is_list(aud),
    do: Enum.any?(aud, &(&1 in audiences))

  defp audience_match?(_aud, _audiences), do: false

  defp not_yet_valid?(nbf, now) when is_integer(nbf), do: nbf > now + @clock_skew_seconds
  defp not_yet_valid?(_nbf, _now), do: false

  # Bounded in BOTH directions. An expired assertion is the obvious case; one
  # minted with a year-long `exp` is a bearer credential sitting in whatever
  # logged it. The two get different reasons because only the first is the
  # vendor doing something wrong — the second is us being stricter than the RFC.
  defp validate_expiry(exp, now) when is_integer(exp) do
    cond do
      exp <= now ->
        {:error, :assertion_expired}

      exp - now > @max_lifetime_seconds + @clock_skew_seconds ->
        {:error, :assertion_lifetime_too_long}

      true ->
        :ok
    end
  end

  defp validate_expiry(_exp, _now), do: {:error, :assertion_expired}
end
