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
        assign(conn, :current_user, user)

      {:ok, user, api_key} ->
        conn
        |> assign(:current_user, user)
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
