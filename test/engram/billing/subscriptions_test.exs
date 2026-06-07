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

    test "Paddle 4xx bubbles as {:error, {:paddle_error, status}}" do
      user = insert(:user)
      insert(:subscription, user: user, paddle_subscription_id: "sub_cancel_422")

      expect(Engram.Paddle.ClientMock, :cancel_subscription, fn _, _, _ ->
        {:error, {:paddle_error, 422}}
      end)

      assert {:error, {:paddle_error, 422}} = Subscriptions.cancel(user)
    end
  end

  describe "preview_plan_change/2" do
    test "calls Paddle preview with items + prorated_immediately mode" do
      user = insert(:user)
      sub = insert(:subscription, user: user, paddle_subscription_id: "sub_preview_ok")

      expect(Engram.Paddle.ClientMock, :preview_subscription_update, fn sub_id, items, opts ->
        assert sub_id == sub.paddle_subscription_id
        assert [%{price_id: "pri_new", quantity: 1}] = items
        assert Keyword.get(opts, :proration_billing_mode) == "prorated_immediately"

        {:ok,
         %{
           old_total: 1400,
           new_total: 700,
           immediate_charge_or_credit: -700,
           next_billed_at: ~U[2026-07-01 00:00:00Z]
         }}
      end)

      assert {:ok, %{immediate_charge_or_credit: -700}} =
               Subscriptions.preview_plan_change(user, "pri_new")
    end

    test "no active subscription returns {:error, :no_active_subscription}" do
      user = insert(:user)

      assert {:error, :no_active_subscription} =
               Subscriptions.preview_plan_change(user, "pri_new")
    end

    test "Paddle error returns {:error, :paddle_unavailable}" do
      user = insert(:user)
      insert(:subscription, user: user, paddle_subscription_id: "sub_preview_err")

      expect(Engram.Paddle.ClientMock, :preview_subscription_update, fn _, _, _ ->
        {:error, :http_500}
      end)

      assert {:error, :paddle_unavailable} =
               Subscriptions.preview_plan_change(user, "pri_new")
    end

    test "Paddle 4xx bubbles as {:error, {:paddle_error, status}}" do
      user = insert(:user)
      insert(:subscription, user: user, paddle_subscription_id: "sub_preview_422")

      expect(Engram.Paddle.ClientMock, :preview_subscription_update, fn _, _, _ ->
        {:error, {:paddle_error, 400}}
      end)

      assert {:error, {:paddle_error, 400}} =
               Subscriptions.preview_plan_change(user, "pri_new")
    end

    test "Paddle 5xx bubbles as {:error, {:paddle_error, status}}" do
      user = insert(:user)
      insert(:subscription, user: user, paddle_subscription_id: "sub_preview_503")

      expect(Engram.Paddle.ClientMock, :preview_subscription_update, fn _, _, _ ->
        {:error, {:paddle_error, 503}}
      end)

      assert {:error, {:paddle_error, 503}} =
               Subscriptions.preview_plan_change(user, "pri_new")
    end
  end

  describe "reverse_cancel/1" do
    test "calls Paddle update with scheduled_change: nil + idempotency key" do
      user = insert(:user)
      sub = insert(:subscription, user: user, paddle_subscription_id: "sub_reverse_ok")

      expect(Engram.Paddle.ClientMock, :update_subscription, fn sub_id, items, opts ->
        assert sub_id == sub.paddle_subscription_id
        assert items == []
        assert Keyword.fetch!(opts, :scheduled_change) == nil
        assert is_binary(Keyword.fetch!(opts, :idempotency_key))
        {:ok, %{scheduled_change: nil}}
      end)

      assert {:ok, %{scheduled_change: nil}} = Subscriptions.reverse_cancel(user)
    end

    test "no active subscription returns {:error, :no_active_subscription}" do
      user = insert(:user)
      assert {:error, :no_active_subscription} = Subscriptions.reverse_cancel(user)
    end

    test "Paddle error returns {:error, :paddle_unavailable}" do
      user = insert(:user)
      insert(:subscription, user: user, paddle_subscription_id: "sub_reverse_err")

      expect(Engram.Paddle.ClientMock, :update_subscription, fn _, _, _ ->
        {:error, :http_500}
      end)

      assert {:error, :paddle_unavailable} = Subscriptions.reverse_cancel(user)
    end
  end

  describe "confirm_plan_change/2" do
    test "calls Paddle update with idempotency key + items" do
      user = insert(:user)
      sub = insert(:subscription, user: user, paddle_subscription_id: "sub_confirm_ok")

      expect(Engram.Paddle.ClientMock, :update_subscription, fn sub_id, items, opts ->
        assert sub_id == sub.paddle_subscription_id
        assert [%{price_id: "pri_new", quantity: 1}] = items
        assert is_binary(Keyword.get(opts, :idempotency_key))
        {:ok, %{transaction_id: "txn_abc"}}
      end)

      assert {:ok, %{transaction_id: "txn_abc"}} =
               Subscriptions.confirm_plan_change(user, "pri_new")
    end

    test "no active subscription returns {:error, :no_active_subscription}" do
      user = insert(:user)

      assert {:error, :no_active_subscription} =
               Subscriptions.confirm_plan_change(user, "pri_new")
    end

    test "Paddle error returns {:error, :paddle_unavailable}" do
      user = insert(:user)
      insert(:subscription, user: user, paddle_subscription_id: "sub_confirm_err")

      expect(Engram.Paddle.ClientMock, :update_subscription, fn _, _, _ ->
        {:error, :http_500}
      end)

      assert {:error, :paddle_unavailable} =
               Subscriptions.confirm_plan_change(user, "pri_new")
    end
  end
end
