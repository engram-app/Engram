defmodule Engram.Billing.SubscriptionsTest do
  use Engram.DataCase, async: true

  import Mox

  alias Engram.Billing.Subscriptions

  setup :verify_on_exit!

  describe "cancel/2" do
    test "calls Paddle with effective_from: :next_billing_period by default and an idempotency key" do
      user = insert(:user)
      sub = insert(:subscription, user: user, paddle_subscription_id: "sub_cancel_default")

      expect(Engram.Paddle.ClientMock, :cancel_subscription, fn sub_id, effective_from, opts ->
        assert sub_id == sub.paddle_subscription_id
        assert effective_from == :next_billing_period
        assert is_binary(Keyword.get(opts, :idempotency_key))
        {:ok, %{effective_at: ~U[2026-07-01 00:00:00Z]}}
      end)

      assert {:ok, %{effective_at: %DateTime{}}} = Subscriptions.cancel(user)
    end

    test "returns {:error, :no_active_subscription} when user has no paddle_subscription_id" do
      user = insert(:user)
      assert {:error, :no_active_subscription} = Subscriptions.cancel(user)
    end

    test "returns {:error, :no_active_subscription} when subscription row exists but paddle_subscription_id is nil" do
      user = insert(:user)
      insert(:subscription, user: user, paddle_subscription_id: nil)
      assert {:error, :no_active_subscription} = Subscriptions.cancel(user)
    end

    test "Paddle error returns {:error, :paddle_unavailable}" do
      user = insert(:user)
      insert(:subscription, user: user, paddle_subscription_id: "sub_cancel_err")

      expect(Engram.Paddle.ClientMock, :cancel_subscription, fn _, _, _ ->
        {:error, :http_500}
      end)

      assert {:error, :paddle_unavailable} = Subscriptions.cancel(user)
    end
  end
end
