defmodule EngramWeb.Plugs.Auth do
  @moduledoc """
  Authentication plug. Supports three auth methods:

  1. API key: `Authorization: Bearer engram_xxx` — for plugin sync, MCP, scripts
  2. Clerk JWT: `Authorization: Bearer <jwt-with-kid>` — for web app (RS256, JWKS)
  3. Legacy JWT: `Authorization: Bearer <jwt-without-kid>` — for backward compat (HS256)

  Sets `conn.assigns.current_user` on success, halts with 401 on failure.
  Logs the failure reason at :warning (category `:auth`, ships to Loki) so
  401s in production are diagnosable (expired token vs bad signature vs
  missing user) without a redeploy.
  """

  import Plug.Conn

  alias EngramWeb.Plugs.Halt

  require Logger

  def init(opts), do: opts

  # Every branch loads the subscription once (Billing.with_subscription/1) so
  # the downstream billing gates (RequireOnboarding, RequireApiRpsBudget)
  # reuse it instead of each re-querying.
  def call(conn, _opts) do
    case authenticate(conn) |> refuse_revoked_grant(conn) do
      {:ok, user, {:grant, claims}} ->
        conn
        |> assign(:current_user, Engram.Billing.with_subscription(user))
        |> assign_grant_claims(claims)

      {:ok, user, :internal_jwt, {:grant, claims}} ->
        # Device-flow / OAuth / MCP access tokens. Downstream cap plugs use
        # `:current_auth_method` to count programmatic traffic without also
        # gating the web SPA (which authes with a Clerk JWT and gets no
        # marker — falls into the bare 2-tuple branch above).
        conn
        |> assign(:current_user, Engram.Billing.with_subscription(user))
        |> assign(:current_auth_method, :internal_jwt)
        |> assign_grant_claims(claims)

      {:ok, user, api_key} ->
        # A raw API key carries no grant. Said here so `OAuthScopeEnforce`
        # does not verify the key as a JWT to find that out.
        conn
        |> assign(:current_user, Engram.Billing.with_subscription(user))
        |> assign(:current_api_key, api_key)
        |> assign_grant_claims(:error)

      {:error, reason} ->
        Logger.warning(
          "auth rejected",
          Engram.Logger.Metadata.with_category(:warning, :auth,
            reason: format_reason(reason),
            request_path: conn.request_path
          )
        )

        # Alertable counter (the log is grep-only). Coarse bounded reason tag.
        _ = Engram.Auth.emit_rejected(reason, :http)

        conn
        |> put_bearer_error(reason)
        |> Halt.json(401, %{error: "unauthorized"})
    end
  end

  # RFC 6750 §3.1: a bearer that was presented but is expired, malformed or
  # unknown is `error="invalid_token"`, which tells an OAuth client to refresh
  # rather than re-authorize from scratch (#1974). No credential at all gets no
  # error code. `:bearer_error` lets `McpAuthChallenge` merge this into its
  # discovery challenge instead of choosing one or the other.
  #
  # RFC 6750 §3: a 401 always carries a challenge, so no credential gets a bare
  # `Bearer`. `McpAuthChallenge` replaces that bare form with its discovery one.
  defp put_bearer_error(conn, :no_auth), do: put_resp_header(conn, "www-authenticate", "Bearer")

  defp put_bearer_error(conn, _reason) do
    conn
    |> assign(:bearer_error, "invalid_token")
    |> put_resp_header("www-authenticate", ~s(Bearer error="invalid_token"))
  end

  defp authenticate(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> Engram.Auth.TokenResolver.resolve(token, surface(conn))
      _ -> {:error, :no_auth}
    end
  end

  # The routes an MCP-audience OAuth token may reach (RFC 8707) declare
  # `private: %{token_surface: :mcp}` in the router: the MCP endpoint, and the
  # upload `get_attachment_upload_target` tells MCP clients to make with the
  # same token. Route privates are set before pipelines run; the controller is not.
  defp surface(%{private: %{token_surface: :mcp}}), do: :mcp
  defp surface(_conn), do: :rest

  # An OAuth access token whose grant is revoked (or not its user's) is
  # refused HERE, before any plug after Auth runs: those stamp activity,
  # record a device fingerprint and charge the API rps budget, none of which
  # a dead credential may do. Both token-JWT branches are read: under the
  # `:local` provider (self-host) an OAuth token resolves as a provider JWT,
  # not `:internal_jwt`. The read is `Accounts.grant_claims/1` (signature
  # only, the resolver just validated the rest; the grant from the
  # `:oauth_grant` cache), and its result is kept for `OAuthScopeEnforce` so
  # the token is not read twice. A raw API key carries no grant, nor does a
  # Clerk JWT (`Engram.Auth.provider_tokens_carry_grants?/0`): it is not read,
  # and the request carries the same "no grant claims" an unreadable one does.
  defp refuse_revoked_grant({:ok, user}, conn) do
    if Engram.Auth.provider_tokens_carry_grants?(),
      do: with_grant(conn, &{:ok, user, &1}),
      else: {:ok, user, {:grant, :error}}
  end

  defp refuse_revoked_grant({:ok, user, :internal_jwt}, conn),
    do: with_grant(conn, &{:ok, user, :internal_jwt, &1})

  defp refuse_revoked_grant(other, _conn), do: other

  defp with_grant(conn, ok) do
    ["Bearer " <> token] = get_req_header(conn, "authorization")

    case Engram.Accounts.grant_claims(token) do
      :revoked -> {:error, :grant_revoked}
      claims -> ok.({:grant, claims})
    end
  end

  defp assign_grant_claims(conn, claims), do: assign(conn, :grant_claims, claims)

  # Joken returns its claim-validation failures as a keyword list (e.g.
  # [message: "Invalid token", claim: "exp", claim_val: 1777359682]). Surface
  # the offending claim so "expired" looks different from "bad signature" in logs.
  defp format_reason(reason) when is_list(reason) do
    case Keyword.get(reason, :claim) do
      nil -> "invalid_token (#{Keyword.get(reason, :message, "unknown")})"
      claim -> "claim_invalid:#{claim}"
    end
  end

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
end
