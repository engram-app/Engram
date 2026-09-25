defmodule Engram.Billing.SubscriptionsRlsTest do
  @moduledoc """
  Pins every KNOWN-USER `subscriptions` access against an enforced tenant
  policy, ahead of that policy existing (#1758 Part 2).

  `subscriptions` has no RLS yet. The policy migration ships separately, after
  a staging rehearsal, so this file applies the policy the migration will add
  INSIDE the sandbox transaction: Postgres DDL is transactional, so the
  `ENABLE`/`FORCE`/`CREATE POLICY` below roll back with the test and never
  reach another file.

  What each test guards is the silent half of trap 1 in
  `docs/context/rls-enforcement-testing-traps.md`: an unscoped read of
  `subscriptions` returns no row rather than raising, so a paying user resolves
  to `:free`, `RequireOnboarding` locks them out, and account deletion skips
  the Paddle cancel and keeps billing a deleted customer.

  The discovery paths (webhooks keyed by `paddle_subscription_id`, the
  reconciliation sweep) need the maintenance pool, which a sandbox-scoped
  policy cannot exercise; see `SubscriptionsMaintenanceTest`.
  """
  use Engram.DataCase, async: false

  import Engram.RlsCase
  import Mox

  alias Engram.Accounts
  alias Engram.Accounts.Lifecycle
  alias Engram.Billing
  alias Engram.Billing.Subscription

  setup :verify_on_exit!

  setup do
    enforce_subscriptions_policy!()

    prev_billing = Application.get_env(:engram, :billing_enabled)
    Application.put_env(:engram, :billing_enabled, true)
    on_exit(fn -> Application.put_env(:engram, :billing_enabled, prev_billing) end)

    user = insert(:user, external_id: nil)

    sub =
      insert(:subscription,
        user: user,
        tier: "pro",
        status: "active",
        paddle_subscription_id: "sub_rls_#{System.unique_integer([:positive])}"
      )

    # A bare struct: `subscription` is NotLoaded, so every read below has to
    # go to the database rather than short-circuit on a preloaded assoc.
    %{user: Accounts.get_user!(user.id), sub: sub}
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

  test "control: the dropped role cannot see the subscription", %{sub: sub} do
    outcome =
      as_prod_role(fn ->
        Repo.one(from(s in Subscription, where: s.id == ^sub.id, select: count(s.id)))
      end)

    assert outcome == {:returned, 0},
           "Harness is not engaging RLS on subscriptions (got #{inspect(outcome)}), " <>
             "so every other assertion in this file is meaningless."
  end

  describe "request path" do
    test "Billing.get_subscription/1 and tier/1 see the paid row", %{user: user, sub: sub} do
      assert {:returned, {%Subscription{id: id}, :pro}} =
               as_prod_role(fn -> {Billing.get_subscription(user), Billing.tier(user)} end)

      assert id == sub.id
    end

    test "Accounts.get_user_with_subscription/1 and !/1 join the row", %{user: user, sub: sub} do
      assert {:returned, {loaded, loaded!}} =
               as_prod_role(fn ->
                 {Accounts.get_user_with_subscription(user.id),
                  Accounts.get_user_with_subscription!(user.id)}
               end)

      assert %Subscription{id: id} = loaded.subscription
      assert id == sub.id
      assert %Subscription{id: ^id} = loaded!.subscription
    end

    test "the auth plug preloads the paid row", %{user: user, sub: sub} do
      {:ok, raw_key, _api_key} = Accounts.create_api_key(user, "rls")

      assert {:returned, conn} =
               as_prod_role(fn ->
                 Phoenix.ConnTest.build_conn()
                 |> Plug.Conn.put_req_header("authorization", "Bearer #{raw_key}")
                 |> EngramWeb.Plugs.Auth.call([])
               end)

      refute conn.halted
      assert %Subscription{id: id, tier: "pro"} = conn.assigns.current_user.subscription
      assert id == sub.id
    end
  end

  describe "account deletion" do
    test "hard_delete/2 finds the subscription and cancels it in Paddle", %{user: user, sub: sub} do
      prev_client = Application.get_env(:engram, :paddle_client)
      Application.put_env(:engram, :paddle_client, Engram.Paddle.ClientMock)
      on_exit(fn -> Application.put_env(:engram, :paddle_client, prev_client) end)

      # Mox verifies on exit: an unscoped lookup sees no subscription, skips the
      # cancel, and the deleted user keeps being billed.
      expect(Engram.Paddle.ClientMock, :cancel_subscription, fn sub_id, :immediately, _opts ->
        assert sub_id == sub.paddle_subscription_id
        {:ok, %{}}
      end)

      assert {:returned, :ok} = as_prod_role(fn -> Lifecycle.hard_delete(user, :user) end)
    end
  end

  describe "subscription.created webhook" do
    defp created_event(user_id, paddle_sub_id) do
      %{
        "event_type" => "subscription.created",
        "data" => %{
          "id" => paddle_sub_id,
          "status" => "active",
          "customer_id" => "ctm_rls",
          "custom_data" => %{"user_id" => user_id},
          "items" => [%{"price" => %{"id" => "pri_starter_monthly_test"}}],
          "current_billing_period" => %{"ends_at" => "2026-12-01T00:00:00Z"}
        }
      }
    end

    test "inserts a new user's row instead of being rejected by the policy" do
      other = insert(:user)

      # INSERT is the one statement the policy REJECTS (42501) rather than
      # filters, so an unscoped insert shows up here as {:raised, _}.
      assert {:returned, {:ok, %Subscription{user_id: user_id, tier: "starter"}}} =
               as_prod_role(fn ->
                 Billing.upsert_from_paddle_event(created_event(other.id, "sub_rls_new"))
               end)

      assert user_id == other.id
    end

    test "a retried delivery upserts the existing row", %{user: user} do
      assert {:returned,
              {:ok, %Subscription{tier: "starter", paddle_subscription_id: "sub_rls_re"}}} =
               as_prod_role(fn ->
                 Billing.upsert_from_paddle_event(created_event(user.id, "sub_rls_re"))
               end)
    end

    test "a paddle id already held by another user is a changeset error, not a 25P02 crash",
         %{sub: sub} do
      other = insert(:user)

      # Without `mode: :savepoint`, the unique violation aborts the tenant
      # transaction and `with_tenant/2`'s role reset dies with 25P02.
      assert {:returned, {:error, %Ecto.Changeset{errors: errors}}} =
               as_prod_role(fn ->
                 Billing.upsert_from_paddle_event(
                   created_event(other.id, sub.paddle_subscription_id)
                 )
               end)

      assert Keyword.has_key?(errors, :paddle_subscription_id)
    end
  end
end
