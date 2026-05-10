defmodule EngramWeb.Plugs.RequireActiveSubscriptionIntegrationTest do
  use EngramWeb.ConnCase, async: true

  alias Engram.{Accounts, Repo}

  # Plug is not wired into the router yet — activate when billing goes live.
  # See router.ex TODO and docs/superpowers/plans/2026-04-06-security-hardening.md Task 1.
  @moduletag :skip

  setup %{conn: conn} do
    user = insert(:user)
    _vault = insert(:vault, user: user, is_default: true)
    {:ok, api_key, _} = Accounts.create_api_key(user, "test-key")
    conn = put_req_header(conn, "authorization", "Bearer #{api_key}")
    {:ok, conn: conn, user: user}
  end

  test "vault-scoped route without subscription returns 403", %{conn: conn} do
    conn = get(conn, "/api/notes/changes?since=2020-01-01T00:00:00Z")
    assert json_response(conn, 403)["error"] == "subscription_required"
  end

  # Regression guard: billing/onboarding routes must NOT be gated.
  test "billing status is reachable without a subscription", %{conn: conn} do
    conn = get(conn, "/api/billing/status")
    refute conn.status == 403
  end

  test "billing checkout session is reachable without a subscription", %{conn: conn} do
    conn = post(conn, "/api/billing/checkout-session", %{})
    refute conn.status == 403
  end

  test "device authorize is reachable without a subscription", %{conn: conn} do
    conn =
      post(conn, "/api/auth/device/authorize", %{
        user_code: "XXXX-XXXX",
        vault_id: "new",
        vault_name: "My Vault"
      })

    refute conn.status == 403
  end

  test "authenticated request with active subscription returns 200", %{conn: conn, user: user} do
    Repo.insert!(
      %Engram.Billing.Subscription{
        user_id: user.id,
        status: "active",
        tier: "starter",
        stripe_customer_id: "cus_test",
        stripe_subscription_id: "sub_test"
      },
      skip_tenant_check: true
    )

    conn = get(conn, "/api/notes/changes?since=2020-01-01T00:00:00Z")
    assert conn.status in [200, 204]
  end

  for status <- ["trialing", "past_due"] do
    test "subscription with status #{status} is accepted", %{conn: conn, user: user} do
      Repo.insert!(
        %Engram.Billing.Subscription{
          user_id: user.id,
          status: unquote(status),
          tier: "starter",
          stripe_customer_id: "cus_test",
          stripe_subscription_id: "sub_test"
        },
        skip_tenant_check: true
      )

      conn = get(conn, "/api/notes/changes?since=2020-01-01T00:00:00Z")
      refute conn.status == 403
    end
  end
end
