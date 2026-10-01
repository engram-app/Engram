defmodule EngramWeb.Plugs.WebActivity do
  @moduledoc """
  Product analytics: counts a request as `:web` activity when it was
  authenticated by a Clerk session, i.e. the SPA.

  `Plugs.Auth` leaves no "credential type" assign, so the web case is the one
  with NEITHER marker: an API key sets `current_api_key`, and a device / OAuth /
  MCP token sets `current_auth_method: :internal_jwt`. The legacy HS256 JWT
  also lands in the unmarked branch and is counted as web; nothing but the SPA
  should still send one.

  Throttling (one event per user per 5 minutes) lives in
  `PostHog.capture_activity/3`, so this is safe on every request.
  """

  alias Engram.Observability.PostHog

  def init(opts), do: opts

  def call(%Plug.Conn{assigns: %{current_user: user} = assigns} = conn, _opts) do
    if web_credential?(assigns), do: PostHog.capture_activity(user, :web)
    conn
  end

  def call(conn, _opts), do: conn

  defp web_credential?(assigns) do
    is_nil(Map.get(assigns, :current_api_key)) and
      Map.get(assigns, :current_auth_method) != :internal_jwt
  end
end
