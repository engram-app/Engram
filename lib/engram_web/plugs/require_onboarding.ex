defmodule EngramWeb.Plugs.RequireOnboarding do
  @moduledoc """
  Halts authenticated requests with 403 `{error: "onboarding_required",
  missing: [...]}` when the user has not completed the signup wizard.
  Onboarding is universal (every account needs profile + vault); the
  `:billing_enabled` flag only affects which steps the wizard runs.
  Self-host (billing off): profile + vault. SaaS: agreement + billing +
  profile + vault.

  Must run after `EngramWeb.Plugs.Auth` (needs `conn.assigns.current_user`)
  and after `EngramWeb.Plugs.RotationLockCheck`. May run before or after
  `VaultPlug`; in this codebase it runs immediately before VaultPlug so
  no vault is resolved for users we'll 403.
  """

  import Plug.Conn

  alias Engram.Onboarding

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns[:current_user] do
      nil ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "authentication_required"}))
        |> halt()

      user ->
        gate(conn, Onboarding.status(user))
    end
  end

  defp gate(conn, %{next_step: :done}), do: conn

  defp gate(
         conn,
         %{
           terms_ok: terms_ok,
           subscription_ok: sub_ok,
           profile_complete: profile_ok,
           next_step: next_step
         } = status
       ) do
    has_vault = Map.get(status, :has_vault, true)
    # uses_obsidian users bypass the vault gate (plugin creates vault later).
    profile = Map.get(status, :profile, %{})
    vault_required = profile_ok and Map.get(profile || %{}, "uses_obsidian") != true

    missing =
      []
      |> then(&if terms_ok, do: &1, else: ["terms" | &1])
      |> then(&if sub_ok, do: &1, else: ["subscription" | &1])
      |> then(&if profile_ok, do: &1, else: ["profile" | &1])
      |> then(&if not vault_required or has_vault, do: &1, else: ["vault" | &1])
      |> Enum.sort()

    body = %{error: "onboarding_required", missing: missing, next_step: next_step}

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, Jason.encode!(body))
    |> halt()
  end
end
