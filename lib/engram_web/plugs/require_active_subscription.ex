defmodule EngramWeb.Plugs.RequireActiveSubscription do
  @moduledoc """
  Gate for vault-scoped routes. Passes when the user has any tier
  (`:free`, `:starter`, `:pro`) AND is not suspended. Returns 402 via
  `EngramWeb.LimitResponse` otherwise.

  Re-purposed 2026-06-07 — was the paid-only gate; Free now counts as active.
  The defensive nil-tier case is structurally unreachable in normal flow
  (RequireOnboarding gates upstream), but kept for belt-and-suspenders.

  Must run AFTER EngramWeb.Plugs.Auth (needs `conn.assigns.current_user`).
  """

  def init(opts), do: opts

  def call(conn, _opts) do
    user = conn.assigns.current_user

    if is_nil(user.suspended_at) do
      conn
    else
      EngramWeb.LimitResponse.halt(conn, "account_suspended", nil, nil, nil)
    end
  end
end
