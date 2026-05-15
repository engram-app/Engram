defmodule EngramWeb.Plugs.RequireOnboarding do
  @moduledoc """
  Halts authenticated requests with 403 `{error: "onboarding_required",
  missing: [...]}` when the user has not completed the signup wizard
  (TOS acceptance + active subscription). Bypassed in self-host mode
  (`billing_enabled=false`).

  Must run after `EngramWeb.Plugs.Auth` (needs `conn.assigns.current_user`)
  and after `EngramWeb.Plugs.RotationLockCheck`. May run before or after
  `VaultPlug`; in this codebase it runs immediately before VaultPlug so
  no vault is resolved for users we'll 403.
  """

  import Plug.Conn

  alias Engram.Onboarding

  def init(opts), do: opts

  def call(conn, _opts) do
    user = conn.assigns[:current_user]

    case Onboarding.status(user) do
      %{enabled: false} ->
        conn

      %{next_step: :done} ->
        conn

      %{terms_ok: terms_ok, subscription_ok: sub_ok} ->
        missing =
          []
          |> then(&if terms_ok, do: &1, else: ["terms" | &1])
          |> then(&if sub_ok, do: &1, else: ["subscription" | &1])
          |> Enum.sort()

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(403, Jason.encode!(%{error: "onboarding_required", missing: missing}))
        |> halt()
    end
  end
end
