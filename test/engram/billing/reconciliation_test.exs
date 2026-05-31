defmodule Engram.Billing.ReconciliationTest do
  use Engram.DataCase, async: false

  import Mox

  alias Engram.Billing.Reconciliation

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    original = Application.get_env(:engram, :billing_enabled)
    Application.put_env(:engram, :billing_enabled, true)
    on_exit(fn -> Application.put_env(:engram, :billing_enabled, original) end)
    :ok
  end

  defp paddle_sub(overrides) do
    Map.merge(
      %{
        "id" => "sub_default",
        "status" => "active",
        "customer_id" => "ctm_default",
        "items" => [%{"price" => %{"id" => "pri_starter_test"}}],
        "current_billing_period" => %{"ends_at" => "2026-06-30T00:00:00Z"}
      },
      overrides
    )
  end

  describe "run/1" do
    test "no drift when Paddle and local match" do
      user = insert(:user)

      insert(:subscription,
        user: user,
        paddle_subscription_id: "sub_ok",
        paddle_customer_id: "ctm_ok",
        tier: "starter",
        status: "active",
        current_period_end: ~U[2026-06-30 00:00:00Z]
      )

      Engram.Paddle.ClientMock
      |> expect(:list_subscriptions, fn _since ->
        {:ok, [paddle_sub(%{"id" => "sub_ok", "customer_id" => "ctm_ok"})]}
      end)

      assert %{drift: [], paddle_total: 1, local_total: 1} = Reconciliation.run(7)
    end

    test "detects :missing_local when Paddle has a subscription we don't" do
      Engram.Paddle.ClientMock
      |> expect(:list_subscriptions, fn _since ->
        {:ok, [paddle_sub(%{"id" => "sub_ghost", "customer_id" => "ctm_ghost"})]}
      end)

      assert %{drift: [%{kind: :missing_local, subscription_id: "sub_ghost"}]} =
               Reconciliation.run(7)
    end

    test "detects :status_mismatch" do
      user = insert(:user)

      insert(:subscription,
        user: user,
        paddle_subscription_id: "sub_status",
        paddle_customer_id: "ctm_status",
        tier: "starter",
        status: "active",
        current_period_end: ~U[2026-06-30 00:00:00Z]
      )

      Engram.Paddle.ClientMock
      |> expect(:list_subscriptions, fn _since ->
        {:ok,
         [paddle_sub(%{"id" => "sub_status", "customer_id" => "ctm_status", "status" => "past_due"})]}
      end)

      assert %{drift: [%{kind: :status_mismatch, subscription_id: "sub_status"}]} =
               Reconciliation.run(7)
    end

    test "detects :tier_mismatch" do
      user = insert(:user)

      insert(:subscription,
        user: user,
        paddle_subscription_id: "sub_tier",
        paddle_customer_id: "ctm_tier",
        tier: "starter",
        status: "active",
        current_period_end: ~U[2026-06-30 00:00:00Z]
      )

      Engram.Paddle.ClientMock
      |> expect(:list_subscriptions, fn _since ->
        {:ok,
         [
           paddle_sub(%{
             "id" => "sub_tier",
             "customer_id" => "ctm_tier",
             "items" => [%{"price" => %{"id" => "pri_pro_test"}}]
           })
         ]}
      end)

      assert %{drift: [%{kind: :tier_mismatch, subscription_id: "sub_tier"}]} =
               Reconciliation.run(7)
    end

    test "detects :period_mismatch beyond 2-minute skew" do
      user = insert(:user)

      insert(:subscription,
        user: user,
        paddle_subscription_id: "sub_period",
        paddle_customer_id: "ctm_period",
        tier: "starter",
        status: "active",
        current_period_end: ~U[2026-06-30 00:00:00Z]
      )

      Engram.Paddle.ClientMock
      |> expect(:list_subscriptions, fn _since ->
        {:ok,
         [
           paddle_sub(%{
             "id" => "sub_period",
             "customer_id" => "ctm_period",
             "current_billing_period" => %{"ends_at" => "2026-07-31T00:00:00Z"}
           })
         ]}
      end)

      assert %{drift: [%{kind: :period_mismatch, subscription_id: "sub_period"}]} =
               Reconciliation.run(7)
    end

    test "tolerates period skew within 2 minutes" do
      user = insert(:user)

      insert(:subscription,
        user: user,
        paddle_subscription_id: "sub_skew",
        paddle_customer_id: "ctm_skew",
        tier: "starter",
        status: "active",
        current_period_end: ~U[2026-06-30 00:00:00Z]
      )

      Engram.Paddle.ClientMock
      |> expect(:list_subscriptions, fn _since ->
        {:ok,
         [
           paddle_sub(%{
             "id" => "sub_skew",
             "customer_id" => "ctm_skew",
             # 1 minute later — within 2-minute tolerance
             "current_billing_period" => %{"ends_at" => "2026-06-30T00:01:00Z"}
           })
         ]}
      end)

      assert %{drift: []} = Reconciliation.run(7)
    end

    test "no-ops when billing disabled (self-host)" do
      Application.put_env(:engram, :billing_enabled, false)

      assert %{drift: [], paddle_total: 0, local_total: 0, skipped: :billing_disabled} =
               Reconciliation.run(7)
    end

    test "returns empty drift when Paddle list_subscriptions errors" do
      Engram.Paddle.ClientMock
      |> expect(:list_subscriptions, fn _since -> {:error, :timeout} end)

      assert %{drift: [], paddle_total: 0, local_total: 0} = Reconciliation.run(7)
    end
  end
end
