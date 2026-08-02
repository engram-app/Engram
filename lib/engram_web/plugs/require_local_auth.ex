defmodule EngramWeb.Plugs.RequireLocalAuth do
  @moduledoc """
  Rejects requests with 404 when AUTH_PROVIDER is not :local.

  Guards local auth endpoints (register, login, refresh, logout) at runtime
  so they are unreachable in Clerk deployments regardless of compile-time config.
  """

  alias EngramWeb.Plugs.Halt

  def init(opts), do: opts

  def call(conn, _opts) do
    if Engram.Auth.supports_credentials?() do
      conn
    else
      Halt.json(conn, 404, %{error: "not_found"})
    end
  end
end
