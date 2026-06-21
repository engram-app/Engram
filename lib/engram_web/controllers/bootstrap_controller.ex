defmodule EngramWeb.BootstrapController do
  @moduledoc """
  One authenticated round-trip that returns everything the SPA needs to decide
  what to render and what the user is allowed to do — replacing the serial
  `GET /api/onboarding/status` + `GET /api/billing/status` + `GET /api/vaults`
  fan-out the app used to make before becoming usable.

  Lives on the onboarding pipeline (Auth, but NOT RequireOnboarding /
  RequireApiRpsBudget) so the client can call it on first load, *before*
  onboarding is complete, to learn `next_step`.

  Payload:

      {
        "onboarding":   { ...identical to GET /api/onboarding/status... },
        "capabilities": { "tier": "...", "limits": { "<key>": <int|bool|null> } },
        "vaults":       { "vaults": [...] },
        "billing":      { ...identical to GET /api/billing/status... }   // only when billing enabled
      }

  `capabilities` is the stable, ETS-cached entitlement matrix (24h TTL +
  invalidation on subscription/override change). `onboarding`, `vaults`, and the
  volatile `billing` slice are computed fresh — they track ordinary user actions
  (accepting terms, creating a vault, connecting a device) that must not lag.
  """
  use EngramWeb, :controller

  alias Engram.Billing
  alias EngramWeb.BillingController
  alias EngramWeb.OnboardingController
  alias EngramWeb.VaultsController

  def show(conn, _params) do
    user = conn.assigns.current_user

    payload = %{
      onboarding: OnboardingController.status_payload(user),
      capabilities: Billing.capabilities(user),
      vaults: VaultsController.index_payload(user)
    }

    payload =
      if Application.get_env(:engram, :billing_enabled, false) do
        Map.put(payload, :billing, BillingController.status_payload(user))
      else
        payload
      end

    json(conn, payload)
  end
end
