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
      (Bearer JWT). The SPA submits the same params plus `vault_ids`
      and an optional user-typed `label` after the consent UI is
      approved, the controller mints an
      authorization code, and returns JSON `{redirect_uri: "..."}` so
      the SPA can `window.location.assign` back to the OAuth client.
  """
  use EngramWeb, :controller

  plug EngramWeb.Plugs.EnforceConnectionCap when action in [:consent]

  alias Engram.Analytics.McpClient
  alias Engram.OAuth
  alias EngramWeb.OAuthMetadata

  # Params we forward to the SPA consent route. RFC 8707 `resource` is
  # pass-through (no validation today; deferred per Phase 7.A plan).
  @forwarded_params ~w(client_id redirect_uri response_type code_challenge
                       code_challenge_method scope state resource)

  def show(conn, params) do
    case OAuth.validate_authorization_request(params) do
      {:ok, validated} ->
        # Anonymous: the browser carries no session on this navigation.
        # `pkce_method_explicit`: an absent method defaults to `plain` in the
        # spec, which we refuse; we read it as S256. Counted so the leniency can
        # be removed once nobody relies on it (#1977).
        props =
          validated
          |> funnel_props()
          |> Map.put(:pkce_method_explicit, is_binary(params["code_challenge_method"]))

        Engram.Analytics.track_anonymous("mcp_oauth_authorize_started", props)
        redirect_to_spa(conn, validated, params)

      {:client_error, code} ->
        render_client_error(conn, code)

      {:server_error, code} ->
        render_server_error(conn, code)

      {:redirect_error, redirect_uri, error, state} ->
        redirect_with_error(conn, redirect_uri, error, state)
    end
  end

  def consent(conn, params) do
    user = conn.assigns.current_user
    # RFC 9207. Fixed at /oauth/authorize on the host the client dialed and
    # carried through the SPA, because this call arrives on another host. Only
    # one of our own issuers is echoed: a forged value is the mix-up attack.
    iss = if OAuthMetadata.issuer?(params["iss"]), do: params["iss"]

    case OAuth.validate_authorization_request(params) do
      {:ok, validated} ->
        case OAuth.mint_authorization_code(
               user,
               Map.put(validated, :iss, iss),
               OAuth.parse_vault_selection(params),
               params["label"]
             ) do
          {:ok, redirect_url} ->
            Engram.Analytics.track(user, "mcp_oauth_granted", funnel_props(validated))

            json(conn, %{redirect_uri: redirect_url})

          {:redirect_error, redirect_uri, error, state} ->
            json(conn, %{
              redirect_uri:
                OAuth.build_redirect(redirect_uri, %{error: error, state: state, iss: iss})
            })

          {:error, _changeset} ->
            json(conn, %{
              redirect_uri:
                OAuth.build_redirect(validated.redirect_uri, %{
                  error: "server_error",
                  state: validated.state,
                  iss: iss
                })
            })
        end

      {:client_error, code} ->
        conn
        |> put_status(400)
        |> json(%{error: code})

      {:server_error, code} ->
        conn
        |> put_status(503)
        |> json(%{error: code})

      {:redirect_error, redirect_uri, error, state} ->
        json(conn, %{
          redirect_uri:
            OAuth.build_redirect(redirect_uri, %{error: error, state: state, iss: iss})
        })
    end
  end

  # Client family + registration method, and the requested vs granted scopes
  # (#1974: a narrowed `offline_access` should be visible, not silent). All
  # bounded labels; never the raw client name, URL or scope text.
  defp funnel_props(validated) do
    validated.client
    |> McpClient.client_props()
    |> Map.merge(%{
      scopes_requested: McpClient.scope_labels(validated.scope_requested),
      scopes_granted: McpClient.scope_labels(validated.scope)
    })
  end

  defp redirect_to_spa(conn, _validated, raw_params) do
    forwarded =
      raw_params
      |> Map.take(@forwarded_params)
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Enum.concat([{"iss", OAuthMetadata.base_url(conn)}])

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

  defp render_client_error(conn, code), do: render_error(conn, 400, :client_error, code)

  # Deliberately NOT the invalid_client page. That copy tells the user their app
  # is not recognized, which is a lie when the truth is that we could not reach
  # or store the client's metadata document — and it is the lie that sent the
  # 2026-08-04 Claude outage looking for a misconfigured connector. 503 also
  # tells well-behaved clients to try again, which is the actual remedy.
  defp render_server_error(conn, code), do: render_error(conn, 503, :server_error, code)

  # The route sits on the `:oauth_api` pipeline, whose `plug :accepts, ["json"]`
  # negotiates a browser's `*/*` down to json. Without put_format/2 these pages
  # would render through the (nonexistent) JSON view.
  defp render_error(conn, status, template, code) do
    conn
    |> put_status(status)
    |> put_format(:html)
    |> render(template, code: code)
  end

  defp redirect_with_error(conn, redirect_uri, error, state) do
    iss = OAuthMetadata.base_url(conn)
    location = OAuth.build_redirect(redirect_uri, %{error: error, state: state, iss: iss})
    conn |> put_status(302) |> redirect(external: location)
  end
end
