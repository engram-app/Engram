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

  # COMPAT SHIM, remove in a later contract PR (with the route and the
  # `index_status` key below). The search-coverage cap was removed, so nothing
  # is ever unsearchable; SPA bundles from before the removal still read this
  # and treat `indexed < total` as "show the banner". Zeros never show it.
  @no_unsearchable_notes %{indexed: 0, total: 0}

  @doc false
  def index_status(conn, _params), do: json(conn, @no_unsearchable_notes)

  def show(conn, _params) do
    user = conn.assigns.current_user
    scope = Engram.Permissions.vault_scope(conn)

    # Every DB read below runs in ONE tenant transaction (each cache loader's
    # own with_tenant nests in it for free), so a cold page load pays one
    # BEGIN/enter/COMMIT instead of one per loader. The DEK is warmed first:
    # a DekCache miss unwraps through KMS, which must not run inside it.
    _ = Engram.Crypto.get_dek(user)
    payload = Engram.Repo.with_tenant!(user.id, fn -> payload(user, scope) end)
    json(conn, payload)
  end

  defp payload(user, scope) do
    payload = %{
      onboarding: OnboardingController.status_payload(user),
      capabilities: Billing.capabilities(user),
      # Compat shim, see `@no_unsearchable_notes`.
      index_status: @no_unsearchable_notes,
      vaults: VaultsController.index_payload(user, scope)
    }

    if Application.get_env(:engram, :billing_enabled, false),
      do: Map.put(payload, :billing, BillingController.status_payload(user)),
      else: payload
  end
end
