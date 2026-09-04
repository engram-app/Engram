defmodule EngramWeb.OAuthAuthorizeHTML do
  @moduledoc """
  The two HTML error pages `GET /oauth/authorize` can answer with.

  These were hand-built strings interpolated through a private `html_escape/1`
  and handed to `send_resp/3`. The copy is unchanged; what changed is that
  escaping is now a property of HEEx rather than of remembering to call the
  helper. `@code` is an internal literal today (`invalid_request`,
  `invalid_client`, `invalid_redirect_uri`, `temporarily_unavailable`) and the
  template is what keeps that from mattering if it ever stops being one.

  No layout: `use Phoenix.Controller, formats: [...]` registers views but no
  layouts, and these pages load nothing — the `:oauth_api` pipeline pins them
  under `default-src 'none'`.
  """
  use EngramWeb, :html

  def client_error(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html>
      <body>
        <h1>Authorization error</h1>
        <p>Error: <code>{@code}</code>.</p>
        <p>
          The OAuth client or redirect URI is not recognized. The request was rejected to prevent
          code-leak attacks.
        </p>
      </body>
    </html>
    """
  end

  def server_error(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html>
      <body>
        <h1>Authorization temporarily unavailable</h1>
        <p>Error: <code>{@code}</code>.</p>
        <p>
          We could not verify this application's metadata just now. This is a problem on our side,
          not with the app — please try connecting again in a moment.
        </p>
      </body>
    </html>
    """
  end
end
