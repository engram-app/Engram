defmodule Engram.Billing.SubscriptionsMaintenanceTest do
  @moduledoc """
  Pins the `subscriptions` DISCOVERY paths to `Engram.Repo.Maintenance` (#1758
  Part 2): Paddle webhooks that arrive carrying only a
  `paddle_subscription_id`, and the reconciliation sweep. Neither has a tenant
  to scope by at entry, so under an enforced policy the app pool finds nothing
  and the webhook reports `:subscription_not_found` (a cancellation or renewal
  silently dropped), while reconciliation reports every paying user as
  `:missing_local`.

  Trap 9 of `docs/context/rls-enforcement-testing-traps.md`, with one change
  forced by `subscriptions` having no RLS yet: the policy is applied and
  COMMITTED here rather than inside the sandbox. A sandbox-scoped `ALTER
  TABLE` holds an ACCESS EXCLUSIVE lock until the test ends, and the
  maintenance pool is a second connection, so its read would block on that
  lock forever. Fixtures are committed for the same reason (the second
  connection cannot see sandbox rows).

  Everything committed is undone in `on_exit`, which is registered BEFORE the
  sandbox owner starts: on_exit is LIFO, so the owner is stopped (rolling back
  the sandbox writes and releasing their row locks) before the cleanup runs.
  Hence `ExUnit.Case` and a hand-started sandbox instead of `Engram.DataCase`,
  whose owner-stop would otherwise run LAST and deadlock the cleanup.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import Engram.Factory
  import Engram.RlsCase
  import Mox

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Billing
  alias Engram.Billing.Reconciliation
  alias Engram.Billing.Subscription
  alias Engram.Repo
  alias Engram.Repo.Maintenance

  setup :verify_on_exit!

  setup do
    # Defensive: a crashed earlier run must not leave the policy behind.
    Sandbox.unboxed_run(Repo, &drop_subscriptions_policy!/0)

    {user, sub} =
      Sandbox.unboxed_run(Repo, fn ->
        enforce_subscriptions_policy!()
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
        drop_subscriptions_policy!()
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

  # The policy the #1758 migration will add, mirroring the other tenant tables.
  defp enforce_subscriptions_policy! do
    Repo.query!("ALTER TABLE subscriptions ENABLE ROW LEVEL SECURITY")
    Repo.query!("ALTER TABLE subscriptions FORCE ROW LEVEL SECURITY")

    Repo.query!("""
    CREATE POLICY tenant_isolation_subscriptions ON subscriptions
      USING (user_id::text = (SELECT current_setting('app.current_tenant', true)))
      WITH CHECK (user_id::text = (SELECT current_setting('app.current_tenant', true)))
    """)
  end

  defp drop_subscriptions_policy! do
    Repo.query!("DROP POLICY IF EXISTS tenant_isolation_subscriptions ON subscriptions")
    Repo.query!("ALTER TABLE subscriptions NO FORCE ROW LEVEL SECURITY")
    Repo.query!("ALTER TABLE subscriptions DISABLE ROW LEVEL SECURITY")
  end

  defp event(type, sub, status, price_id) do
    %{
      "event_type" => type,
      "data" => %{
        "id" => sub.paddle_subscription_id,
        "status" => status,
        "customer_id" => sub.paddle_customer_id,
        "items" => [%{"price" => %{"id" => price_id}}],
        "current_billing_period" => %{"ends_at" => "2026-12-01T00:00:00Z"}
      }
    }
  end

  test "control: the app pool, as it runs here, cannot see the row", %{sub: sub} do
    assert {:returned, 0} =
             as_prod_role(fn ->
               Repo.one(from(s in Subscription, where: s.id == ^sub.id, select: count(s.id)))
             end)
  end

  test "subscription.updated finds the row and writes it under the owner's tenant", %{sub: sub} do
    result =
      as_prod_role_committing(fn ->
        Billing.upsert_from_paddle_event(
          event("subscription.updated", sub, "past_due", "pri_pro_monthly_test")
        )
      end)

    assert {:ok, %Subscription{status: "past_due", tier: "pro"}} = result

    # Read back on the sandbox connection: the write is uncommitted there.
    assert %Subscription{status: "past_due", tier: "pro"} = Repo.get!(Subscription, sub.id)
  end

  test "subscription.canceled finds the row and writes it under the owner's tenant", %{
    user: user,
    sub: sub
  } do
    result =
      as_prod_role_committing(fn ->
        Billing.upsert_from_paddle_event(
          event("subscription.canceled", sub, "canceled", "pri_starter_monthly_test")
        )
      end)

    assert {:ok, %Subscription{status: "canceled"}} = result
    assert %Subscription{status: "canceled"} = Repo.get!(Subscription, sub.id)

    # The user write shares the tenant transaction with the subscription write.
    assert %{free_tier_accepted_at: %DateTime{}} = Repo.get!(Engram.Accounts.User, user.id)
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
