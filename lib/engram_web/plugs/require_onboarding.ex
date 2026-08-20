defmodule EngramWeb.Plugs.RequireOnboarding do
  @moduledoc """
  Halts authenticated requests with 403 `{error: "onboarding_required",
  missing: [...]}` when the user has not completed the signup wizard.
  Onboarding is universal (every account needs profile + vault); the
  `:billing_enabled` flag only affects which steps the wizard runs.
  Self-host (billing off): profile + vault. SaaS: agreement + billing +
  profile + vault.

  This is the HTTP half of the gate only. The verdict itself lives in
  `Engram.Onboarding.gate/1` because the WebSocket sync path (`sync:` /
  `crdt:` channel joins) must enforce the same rule and a Plug never runs
  on a socket. Adding a route to the vault pipeline gets you this plug;
  adding a *channel* does not — call `Onboarding.gate/1` from its `join/3`.

  Accepts the same options as `Engram.Onboarding.gate/2` — notably
  `skip_vault: true`, for routes whose own job is creating the first vault
  (see `EngramWeb.DeviceAuthController`).

  Must run after `EngramWeb.Plugs.Auth` (needs `conn.assigns.current_user`)
  and after `EngramWeb.Plugs.RotationLockCheck`. May run before or after
  `VaultPlug`; in this codebase it runs immediately before VaultPlug so
  no vault is resolved for users we'll 403.
  """

  alias Engram.Onboarding
  alias EngramWeb.Plugs.Halt

  def init(opts), do: opts

  def call(conn, opts) do
    case conn.assigns[:current_user] do
      nil ->
        Halt.json(conn, 401, %{error: "authentication_required"})

      user ->
        case Onboarding.gate(user, opts) do
          :ok ->
            conn

          {:error, missing, next_step} ->
            Halt.json(conn, 403, %{
              error: "onboarding_required",
              missing: missing,
              next_step: next_step
            })
        end
    end
  end
end
