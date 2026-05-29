defmodule EngramWeb.Plugs.RequireAdmin do
  @moduledoc """
  Gates /api/admin routes. 404 unless AUTH_PROVIDER=local (feature hidden
  under Clerk). 403 unless current_user is an active (non-suspended) admin.
  Run AFTER EngramWeb.Plugs.Auth so current_user is loaded.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      not Engram.Auth.supports_credentials?() ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{error: "not_found"}))
        |> halt()

      admin?(conn.assigns[:current_user]) ->
        conn

      true ->
        conn |> put_status(403) |> json(%{error: "forbidden"}) |> halt()
    end
  end

  defp admin?(%{role: "admin", suspended_at: nil}), do: true
  defp admin?(_), do: false
end
