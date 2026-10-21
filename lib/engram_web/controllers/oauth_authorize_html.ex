defmodule EngramWeb.OAuthAuthorizeHTML do
  @moduledoc """
  The HTML pages `GET /oauth/authorize` answers with instead of redirecting.

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

  # A bare GET: a crawler or a curious human, not an OAuth client. The docs
  # URL is the one `WellKnownController` advertises as `resource_documentation`.
  def not_a_connect_attempt(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html>
      <body>
        <h1>Engram connector</h1>
        <p>
          This address is used by AI tools to connect to Engram. See
          <a href="https://engram.page/docs/mcp">how to connect an AI tool</a>.
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
