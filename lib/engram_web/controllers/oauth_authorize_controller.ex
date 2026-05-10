defmodule EngramWeb.OAuthAuthorizeController do
  @moduledoc """
  Authorization endpoint for OAuth 2.1 (RFC 6749 §4.1 + RFC 7636 PKCE).

  GET renders a server-side consent page (vault picker). POST handles
  the consent submission, mints an authorization code, and 302s back to
  the client's `redirect_uri` with `code` + `state`.

  Both verbs require an authenticated user (`Authorization: Bearer ...`)
  via the existing `EngramWeb.Plugs.Auth`. Browser cookie session for
  unauth'd users is handled in Phase 7 (consent UX iteration); today
  the SPA acts as the user-agent that mediates this flow.
  """
  use EngramWeb, :controller

  alias Engram.OAuth
  alias Engram.Vaults

  def show(conn, params) do
    case OAuth.validate_authorization_request(params) do
      {:ok, validated} ->
        render_consent(conn, validated)

      {:client_error, code} ->
        render_client_error(conn, code)

      {:redirect_error, redirect_uri, error, state} ->
        redirect_with_error(conn, redirect_uri, error, state)
    end
  end

  def submit(conn, params) do
    user = conn.assigns.current_user

    case OAuth.validate_authorization_request(params) do
      {:ok, validated} ->
        vault_choice = params["vault_choice"] || "vault:*"

        case OAuth.mint_authorization_code(user, validated, vault_choice) do
          {:ok, redirect_url} ->
            conn |> put_status(302) |> redirect(external: redirect_url)

          {:redirect_error, redirect_uri, error, state} ->
            redirect_with_error(conn, redirect_uri, error, state)

          {:error, _changeset} ->
            redirect_with_error(conn, validated.redirect_uri, "server_error", validated.state)
        end

      {:client_error, code} ->
        render_client_error(conn, code)

      {:redirect_error, redirect_uri, error, state} ->
        redirect_with_error(conn, redirect_uri, error, state)
    end
  end

  defp render_consent(conn, validated) do
    user = conn.assigns.current_user
    vaults = Vaults.list_vaults(user)

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, consent_html(validated, vaults, user))
  end

  defp consent_html(validated, vaults, user) do
    """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>Authorize #{html_escape(validated.client_name)} — Engram</title>
      <style>
        body { font-family: system-ui, sans-serif; max-width: 480px; margin: 4rem auto; padding: 1rem; }
        h1 { font-size: 1.25rem; }
        fieldset { border: 1px solid #ccc; padding: 1rem; margin: 1rem 0; }
        legend { font-weight: 600; }
        label { display: block; padding: 0.25rem 0; }
        button { padding: 0.5rem 1rem; font-size: 1rem; cursor: pointer; }
      </style>
    </head>
    <body>
      <h1>Authorize <strong>#{html_escape(validated.client_name || "this app")}</strong> to access your Engram</h1>
      <p>Signed in as #{html_escape(user.email)}.</p>
      <form action="/oauth/authorize" method="post">
        #{hidden(validated)}
        <fieldset>
          <legend>Which vault?</legend>
          #{vault_radios(vaults)}
          <label>
            <input type="radio" name="vault_choice" value="vault:*" checked>
            All vaults
          </label>
        </fieldset>
        <button type="submit">Approve</button>
      </form>
    </body>
    </html>
    """
  end

  defp hidden(validated) do
    [
      {"client_id", validated.client_id},
      {"redirect_uri", validated.redirect_uri},
      {"response_type", "code"},
      {"code_challenge", validated.code_challenge},
      {"code_challenge_method", validated.code_challenge_method},
      {"scope", validated.scope},
      {"state", validated.state}
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Enum.map_join("\n", fn {k, v} ->
      ~s(<input type="hidden" name="#{k}" value="#{html_escape(v)}">)
    end)
  end

  defp vault_radios([]), do: ""

  defp vault_radios(vaults) do
    Enum.map_join(vaults, "\n", fn v ->
      ~s(<label><input type="radio" name="vault_choice" value="vault:#{v.id}"> #{html_escape(v.slug)}</label>)
    end)
  end

  defp html_escape(nil), do: ""

  defp html_escape(s) when is_binary(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp html_escape(other), do: html_escape(to_string(other))

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
    params = %{error: error, state: state} |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" end)
    sep = if String.contains?(redirect_uri, "?"), do: "&", else: "?"
    location = redirect_uri <> sep <> URI.encode_query(params)

    conn |> put_status(302) |> redirect(external: location)
  end
end
