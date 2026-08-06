defmodule EngramWeb.Plugs.RequireAdmin do
  @moduledoc """
  Gates /api/admin routes. 404 unless AUTH_PROVIDER=local (feature hidden
  under Clerk). 403 unless current_user is an active (non-suspended) admin.
  Run AFTER EngramWeb.Plugs.Auth so current_user is loaded.
  """
  alias EngramWeb.Plugs.Halt

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      not Engram.Auth.supports_credentials?() ->
        Halt.json(conn, 404, %{error: "not_found"})

      admin?(conn.assigns[:current_user]) ->
        conn

      true ->
        Halt.json(conn, 403, %{error: "forbidden"})
    end
  end

  defp admin?(%{role: "admin", suspended_at: nil, deleted_at: nil}), do: true
  defp admin?(_), do: false
end
