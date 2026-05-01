defmodule EngramWeb.Plugs.RequireSession do
  @moduledoc """
  Requires that the request is authenticated by a session/JWT, not by an
  API key. Use on routes that manage credentials or other account-wide
  primitives — an API key restricted to one vault must not be able to
  enumerate, create, or revoke other API keys for the same user.

  Assumes `EngramWeb.Plugs.Auth` has already run. If `conn.assigns` has
  `:current_api_key`, the request is halted with 403.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case Map.get(conn.assigns, :current_api_key) do
      nil ->
        conn

      _api_key ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(403, Jason.encode!(%{error: "api_key_not_allowed"}))
        |> halt()
    end
  end
end
