defmodule EngramWeb.Plugs.RequireOperator do
  @moduledoc """
  Gates the operator insights (`/api/operator`), the one cross-tenant read
  plane on SaaS. Passes only an active `users.role == "operator"` on a
  first-party browser session; everyone else gets 404, so the plane is
  invisible. An operator's API key, plugin token or OAuth grant is refused
  too: those credentials sit on disks and in third-party apps, and must not
  inherit a read of every tenant.

  The role is granted only by `Engram.Release.grant_operator/1`. Run AFTER
  `EngramWeb.Plugs.Auth` and `EngramWeb.Plugs.OAuthScopeEnforce`, which set
  the assigns checked here (the same ones `RequireSession` keys on).
  """
  alias EngramWeb.Plugs.Halt

  def init(opts), do: opts

  def call(conn, _opts) do
    if operator?(conn.assigns[:current_user]) and session?(conn.assigns),
      do: conn,
      else: Halt.json(conn, 404, %{error: "not_found"})
  end

  defp operator?(%{role: "operator", suspended_at: nil, deleted_at: nil}), do: true
  defp operator?(_), do: false

  defp session?(assigns) do
    not Enum.any?([:current_api_key, :oauth_scope, :oauth_grant_id, :device_token], &assigns[&1])
  end
end
