defmodule EngramWeb.OAuthAuthorizeController do
  @moduledoc """
  Authorization endpoint for OAuth 2.1 (RFC 6749 §4.1 + RFC 7636 PKCE).

  Phase 7.A — SPA mediation:

    * `GET /oauth/authorize` is **public**. It validates client_id,
      redirect_uri, response_type, PKCE, and scope, then 302s to
      `/oauth/consent?<all-params>` on the SPA. Browsers don't carry
      `Authorization: Bearer ...` on navigations, so the React SPA
      mediates consent under the user's existing JWT session.

    * `POST /api/oauth/authorize/consent` is **user-authenticated**
      (Bearer JWT). The SPA submits the same params plus `vault_choice`
      after the consent UI is approved, the controller mints an
      authorization code, and returns JSON `{redirect_uri: "..."}` so
      the SPA can `window.location.assign` back to the OAuth client.
  """
  use EngramWeb, :controller

  plug EngramWeb.Plugs.EnforceConnectionCap when action in [:consent]

  alias Engram.OAuth

  # Params we forward to the SPA consent route. RFC 8707 `resource` is
  # pass-through (no validation today; deferred per Phase 7.A plan).
  @forwarded_params ~w(client_id redirect_uri response_type code_challenge
                       code_challenge_method scope state resource)

  def show(conn, params) do
    case OAuth.validate_authorization_request(params) do
      {:ok, validated} ->
        redirect_to_spa(conn, validated, params)

      {:client_error, code} ->
        render_client_error(conn, code)

      {:redirect_error, redirect_uri, error, state} ->
        redirect_with_error(conn, redirect_uri, error, state)
    end
  end

  def consent(conn, params) do
    user = conn.assigns.current_user

    case OAuth.validate_authorization_request(params) do
      {:ok, validated} ->
        vault_choice = params["vault_choice"] || "vault:*"

        case OAuth.mint_authorization_code(user, validated, vault_choice) do
          {:ok, redirect_url} ->
            json(conn, %{redirect_uri: redirect_url})

          {:redirect_error, redirect_uri, error, state} ->
            json(conn, %{redirect_uri: build_error_url(redirect_uri, error, state)})

          {:error, _changeset} ->
            json(conn, %{
              redirect_uri:
                build_error_url(validated.redirect_uri, "server_error", validated.state)
            })
        end

      {:client_error, code} ->
        conn
        |> put_status(400)
        |> json(%{error: code})

      {:redirect_error, redirect_uri, error, state} ->
        json(conn, %{redirect_uri: build_error_url(redirect_uri, error, state)})
    end
  end

  defp redirect_to_spa(conn, _validated, raw_params) do
    forwarded =
      raw_params
      |> Map.take(@forwarded_params)
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)

    query = URI.encode_query(forwarded)

    # The SPA consent page lives on the frontend host. Same-origin on self-host
    # (relative `/oauth/consent` resolves correctly), but after the saas eject
    # this controller is reached on api./mcp.engram.page while the SPA is on
    # app.engram.page — a relative redirect would resolve to the wrong host and
    # 404. When `:frontend_base_url` is configured, redirect there absolutely;
    # otherwise stay relative (self-host / dev).
    conn = put_status(conn, 302)

    case Application.get_env(:engram, :frontend_base_url) do
      url when is_binary(url) and url != "" ->
        redirect(conn, external: "#{String.trim_trailing(url, "/")}/oauth/consent?#{query}")

      _ ->
        redirect(conn, to: "/oauth/consent?#{query}")
    end
  end

  defp render_client_error(conn, code) do
    body = """
    <!doctype html>
    <html><body>
    <h1>Authorization error</h1>
    <p>Error: <code>#{html_escape(code)}</code>.</p>
    <p>The OAuth client or redirect URI is not recognized. The request was rejected to prevent code-leak attacks.</p>
    </body></html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(400, body)
  end

  defp redirect_with_error(conn, redirect_uri, error, state) do
    location = build_error_url(redirect_uri, error, state)
    conn |> put_status(302) |> redirect(external: location)
  end

  defp build_error_url(redirect_uri, error, state) do
    params = %{error: error, state: state} |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" end)
    sep = if String.contains?(redirect_uri, "?"), do: "&", else: "?"
    redirect_uri <> sep <> URI.encode_query(params)
  end

  defp html_escape(s) when is_binary(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
