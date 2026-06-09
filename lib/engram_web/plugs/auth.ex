defmodule EngramWeb.Plugs.Auth do
  @moduledoc """
  Authentication plug. Supports three auth methods:

  1. API key: `Authorization: Bearer engram_xxx` — for plugin sync, MCP, scripts
  2. Clerk JWT: `Authorization: Bearer <jwt-with-kid>` — for web app (RS256, JWKS)
  3. Legacy JWT: `Authorization: Bearer <jwt-without-kid>` — for backward compat (HS256)

  Sets `conn.assigns.current_user` on success, halts with 401 on failure.
  Logs the failure reason at :info so 401s in production are diagnosable
  (expired token vs bad signature vs missing user) without a redeploy.
  """

  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    case authenticate(conn) do
      {:ok, user} ->
        assign(conn, :current_user, with_billing_assoc(user))

      {:ok, user, :internal_jwt} ->
        # Device-flow / OAuth / MCP access tokens. Downstream cap plugs use
        # `:current_auth_method` to count programmatic traffic without also
        # gating the web SPA (which authes with a Clerk JWT and gets no
        # marker — falls into the bare 2-tuple branch above).
        conn
        |> assign(:current_user, with_billing_assoc(user))
        |> assign(:current_auth_method, :internal_jwt)

      {:ok, user, api_key} ->
        conn
        |> assign(:current_user, with_billing_assoc(user))
        |> assign(:current_api_key, api_key)

      {:error, reason} ->
        Logger.info("auth rejected",
          reason: format_reason(reason),
          request_path: conn.request_path
        )

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
        |> halt()
    end
  end

  defp authenticate(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> Engram.Auth.TokenResolver.resolve(token)
      _ -> {:error, :no_auth}
    end
  end

  # Load the subscription once here so the downstream billing gates
  # (RequireOnboarding, RequireApiRpsBudget, RequireApiWriteEnabled) reuse the
  # preloaded assoc instead of each re-querying. Skipped in self-host mode,
  # where no billing gate runs and the extra read would be pure waste.
  defp with_billing_assoc(user) do
    if Application.get_env(:engram, :billing_enabled, false) do
      Engram.Repo.preload(user, :subscription)
    else
      user
    end
  end

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
