defmodule Engram.BillingTest do
  use Engram.DataCase, async: true

  alias Engram.Billing

  describe "tier/1" do
    test "returns :none for user with no subscription" do
      user = insert(:user)
      assert Billing.tier(user) == :none
    end

    test "returns tier atom for user with active subscription" do
      user = insert(:user)
      insert(:subscription, user: user, tier: "starter", status: "active")
      assert Billing.tier(user) == :starter
    end

    test "returns tier atom for user with trialing subscription" do
      user = insert(:user)
      insert(:subscription, user: user, tier: "starter", status: "trialing")
      assert Billing.tier(user) == :starter
    end

    test "returns :none for user with canceled subscription" do
      user = insert(:user)
      insert(:subscription, user: user, tier: "starter", status: "canceled")
      assert Billing.tier(user) == :none
    end
  end

  describe "active?/1" do
    test "returns false for user with no subscription" do
      user = insert(:user)
      assert Billing.active?(user) == false
    end

    test "returns true for user with trialing subscription" do
      user = insert(:user)
      insert(:subscription, user: user, status: "trialing")
      assert Billing.active?(user) == true
    end

    test "returns true for user with active subscription" do
      user = insert(:user)
      insert(:subscription, user: user, status: "active")
      assert Billing.active?(user) == true
    end

    test "returns true for user with past_due subscription" do
      user = insert(:user)
      insert(:subscription, user: user, status: "past_due")
      assert Billing.active?(user) == true
    end

    test "returns false for user with canceled subscription" do
      user = insert(:user)
      insert(:subscription, user: user, status: "canceled")
      assert Billing.active?(user) == false
    end
  end

  describe "get_subscription/1" do
    test "returns nil for user with no subscription" do
      user = insert(:user)
      assert Billing.get_subscription(user) == nil
    end

    test "returns subscription for user" do
      user = insert(:user)
      sub = insert(:subscription, user: user)
      result = Billing.get_subscription(user)
      assert result.id == sub.id
    end
  end

  describe "trial_days_remaining/1" do
    test "returns days remaining for trialing subscription" do
      user = insert(:user)
      period_end = DateTime.add(DateTime.utc_now(), 5, :day)
      insert(:subscription, user: user, status: "trialing", current_period_end: period_end)
      days = Billing.trial_days_remaining(user)
      assert days >= 4 and days <= 5
    end

    test "returns 0 for user with no subscription" do
      user = insert(:user)
      assert Billing.trial_days_remaining(user) == 0
    end

    test "returns 0 for user with active (non-trial) subscription" do
      user = insert(:user)
      insert(:subscription, user: user, status: "active")
      assert Billing.trial_days_remaining(user) == 0
    end
  end

  # Webhook upsert tests live with the Paddle wire-up commit — Stripe-shaped
  # fixtures (checkout.session.completed, customer.subscription.*) are gone.
end
