defmodule EngramWeb.Plugs.RequireActiveSubscription do
  @moduledoc """
  Gate for vault-scoped routes. Passes when the user has any tier
  (`:free`, `:starter`, `:pro`) AND is not suspended. Returns 402 with the
  standardized limit-response shape otherwise.

  Re-purposed 2026-06-07 — was the paid-only gate; Free now counts as active.
  The defensive nil-tier case is structurally unreachable in normal flow
  (RequireOnboarding gates upstream), but kept for belt-and-suspenders.

  Must run AFTER EngramWeb.Plugs.Auth (needs `conn.assigns.current_user`).

  Once `EngramWeb.LimitResponse` lands (Task 3.1 of the Free Tier Launch
  plan), the inlined `halt_402/2` body will be replaced with
  `EngramWeb.LimitResponse.halt(conn, reason, nil, nil, nil)`.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    user = conn.assigns.current_user

    cond do
      not is_nil(user.suspended_at) ->
        halt_402(conn, "account_suspended")

      true ->
        conn
    end
  end

  defp halt_402(conn, reason) do
    upgrade_url =
      Application.get_env(
        :engram,
        :upgrade_url,
        "https://app.engram.page/settings/billing"
      )

    body = %{
      "error" => "limit_exceeded",
      "reason" => reason,
      "tier" => tier_string(conn.assigns[:current_user]),
      "limit_key" => nil,
      "limit" => nil,
      "current" => nil,
      "upgrade_url" => upgrade_url
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(402, Jason.encode!(body))
    |> halt()
  end

  defp tier_string(nil), do: nil
  defp tier_string(user) do
    case Engram.Billing.tier(user) do
      nil -> nil
      atom -> Atom.to_string(atom)
    end
  end
end
