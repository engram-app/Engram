defmodule Engram.Billing.SubscriptionsMaintenanceTest do
  @moduledoc """
  Pins the reconciliation sweep to `Engram.Repo.Maintenance` (#1758 Part 2).
  It spans every tenant, so on the app pool the enforced `subscriptions`
  policy would hide each row and every paying user would page as
  `:missing_local`. It reads through the `maintenance_all` policy instead.

  The Paddle webhook is NOT here any more: it discovers by
  `paddle_subscription_id` on the app pool through `subscriptions_discovery`
  (see `SubscriptionsRlsTest`).

  Fixtures are COMMITTED, because the maintenance pool is a second connection
  that cannot see sandbox rows, and undone in `on_exit`, registered BEFORE the
  sandbox owner starts: on_exit is LIFO, so the owner is stopped (rolling back
  sandbox writes and releasing their row locks) before the cleanup runs. Hence
  `ExUnit.Case` and a hand-started sandbox instead of `Engram.DataCase`.
  """
  use ExUnit.Case, async: false

  import Engram.Factory
  import Engram.RlsCase
  import Mox

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Billing.Reconciliation
  alias Engram.Repo
  alias Engram.Repo.Maintenance

  setup :verify_on_exit!

  setup do
    {user, sub} =
      Sandbox.unboxed_run(Repo, fn ->
        user = insert(:user)

        sub =
          insert(:subscription,
            user: user,
            tier: "starter",
            status: "active",
            paddle_subscription_id: "sub_maint_#{System.unique_integer([:positive])}",
            current_period_end: ~U[2026-06-30 00:00:00Z]
          )

        {user, sub}
      end)

    # Registered first, so it runs LAST (after the owner below is stopped).
    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        # Cascades to the subscription row.
        Repo.delete!(user)
      end)
    end)

    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    config = Keyword.merge(Repo.config(), pool: DBConnection.ConnectionPool, pool_size: 1)
    start_supervised!({Maintenance, config})
    Application.put_env(:engram, :maintenance_repo_enabled, true)
    on_exit(fn -> Application.delete_env(:engram, :maintenance_repo_enabled) end)

    prev_billing = Application.get_env(:engram, :billing_enabled)
    Application.put_env(:engram, :billing_enabled, true)
    on_exit(fn -> Application.put_env(:engram, :billing_enabled, prev_billing) end)

    %{user: user, sub: sub}
  end

  test "reconciliation matches the local row instead of reporting :missing_local", %{sub: sub} do
    expect(Engram.Paddle.ClientMock, :list_subscriptions, fn _since ->
      {:ok,
       [
         %{
           "id" => sub.paddle_subscription_id,
           "status" => "active",
           "customer_id" => sub.paddle_customer_id,
           "items" => [%{"price" => %{"id" => "pri_starter_monthly_test"}}],
           "current_billing_period" => %{"ends_at" => "2026-06-30T00:00:00Z"}
         }
       ]}
    end)

    assert {:returned, %{drift: [], local_total: 1}} =
             as_prod_role(fn -> Reconciliation.run(7) end)
  end
end
