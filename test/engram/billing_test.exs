defmodule Engram.BillingTest do
  use Engram.DataCase, async: true

  import Mox

  alias Engram.Billing
  alias Engram.Billing.Subscription

  setup :verify_on_exit!

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

  describe "create_portal_session/1" do
    test "returns portal URL from the Paddle client" do
      user = insert(:user)
      insert(:subscription, user: user, paddle_customer_id: "ctm_portal_test")

      expect(Engram.Paddle.ClientMock, :create_customer_portal_session, fn "ctm_portal_test" ->
        {:ok, "https://customer-portal.paddle.com/abc"}
      end)

      assert {:ok, "https://customer-portal.paddle.com/abc"} = Billing.create_portal_session(user)
    end

    test "returns :no_subscription when user has no subscription" do
      user = insert(:user)
      assert {:error, :no_subscription} = Billing.create_portal_session(user)
    end

    test "propagates client errors" do
      user = insert(:user)
      insert(:subscription, user: user, paddle_customer_id: "ctm_err")

      expect(Engram.Paddle.ClientMock, :create_customer_portal_session, fn _ ->
        {:error, {:paddle_error, 500}}
      end)

      assert {:error, {:paddle_error, 500}} = Billing.create_portal_session(user)
    end

    test "propagates :paddle_not_configured when api key is missing" do
      user = insert(:user)
      insert(:subscription, user: user, paddle_customer_id: "ctm_unconfig")

      expect(Engram.Paddle.ClientMock, :create_customer_portal_session, fn _ ->
        {:error, :paddle_not_configured}
      end)

      assert {:error, :paddle_not_configured} = Billing.create_portal_session(user)
    end
  end

  describe "upsert_from_paddle_event/1" do
    test "subscription.created inserts a new row with custom_data" do
      user = insert(:user)

      event = %{
        "event_type" => "subscription.created",
        "event_id" => "ntf_create_1",
        "data" => %{
          "id" => "sub_paddle_1",
          "status" => "trialing",
          "customer_id" => "ctm_paddle_1",
          "items" => [
            %{"price" => %{"id" => "pri_starter_test"}, "status" => "trialing"}
          ],
          "current_billing_period" => %{
            "starts_at" => "2026-05-13T00:00:00Z",
            "ends_at" => "2026-05-20T00:00:00Z"
          },
          "custom_data" => %{"user_id" => user.id, "affiliate_ref" => "ref_abc"}
        }
      }

      assert {:ok, %Subscription{} = sub} = Billing.upsert_from_paddle_event(event)
      assert sub.user_id == user.id
      assert sub.paddle_customer_id == "ctm_paddle_1"
      assert sub.paddle_subscription_id == "sub_paddle_1"
      assert sub.tier == "starter"
      assert sub.status == "trialing"
      assert sub.custom_data == %{"user_id" => user.id, "affiliate_ref" => "ref_abc"}
    end

    test "retried subscription.created preserves original custom_data (affiliate attribution)" do
      user = insert(:user)

      first_event = %{
        "event_type" => "subscription.created",
        "data" => %{
          "id" => "sub_retry_1",
          "status" => "trialing",
          "customer_id" => "ctm_retry_1",
          "items" => [%{"price" => %{"id" => "pri_starter_test"}}],
          "current_billing_period" => %{"ends_at" => "2026-05-20T00:00:00Z"},
          "custom_data" => %{"user_id" => user.id, "affiliate_ref" => "rf_original"}
        }
      }

      assert {:ok, _} = Billing.upsert_from_paddle_event(first_event)

      # Paddle redelivers. The replay arrives with different (or empty)
      # custom_data — e.g. an operator-replayed event from the dashboard.
      retry_event =
        put_in(first_event, ["data", "custom_data"], %{
          "user_id" => user.id,
          "affiliate_ref" => "rf_replay"
        })

      assert {:ok, _} = Billing.upsert_from_paddle_event(retry_event)

      # Re-fetch — Ecto's on_conflict struct return reflects the changeset, not
      # the DB. The DB row is what we care about.
      reloaded = Billing.get_subscription(user)
      assert reloaded.custom_data["affiliate_ref"] == "rf_original"
    end

    test "subscription.created accepts user_id as string in custom_data" do
      user = insert(:user)

      event = %{
        "event_type" => "subscription.created",
        "data" => %{
          "id" => "sub_paddle_2",
          "status" => "active",
          "customer_id" => "ctm_paddle_2",
          "items" => [%{"price" => %{"id" => "pri_pro_test"}}],
          "current_billing_period" => %{"ends_at" => "2026-06-13T00:00:00Z"},
          "custom_data" => %{"user_id" => to_string(user.id)}
        }
      }

      assert {:ok, %Subscription{tier: "pro"}} = Billing.upsert_from_paddle_event(event)
    end

    test "subscription.created without user_id returns :missing_user_id" do
      event = %{
        "event_type" => "subscription.created",
        "data" => %{
          "id" => "sub_paddle_3",
          "status" => "trialing",
          "customer_id" => "ctm_paddle_3",
          "items" => [%{"price" => %{"id" => "pri_starter_test"}}],
          "current_billing_period" => %{"ends_at" => "2026-05-20T00:00:00Z"},
          "custom_data" => %{}
        }
      }

      assert {:error, :missing_user_id} = Billing.upsert_from_paddle_event(event)
    end

    test "subscription.updated mutates the existing row" do
      user = insert(:user)
      insert(:subscription, user: user, paddle_subscription_id: "sub_upd_1", status: "trialing")

      event = %{
        "event_type" => "subscription.updated",
        "data" => %{
          "id" => "sub_upd_1",
          "status" => "past_due",
          "customer_id" => "ctm_x",
          "items" => [%{"price" => %{"id" => "pri_pro_test"}}],
          "current_billing_period" => %{"ends_at" => "2026-07-01T00:00:00Z"}
        }
      }

      assert {:ok, %Subscription{status: "past_due", tier: "pro"}} =
               Billing.upsert_from_paddle_event(event)
    end

    test "subscription.canceled marks the row canceled" do
      user = insert(:user)
      insert(:subscription, user: user, paddle_subscription_id: "sub_can_1", status: "active")

      event = %{
        "event_type" => "subscription.canceled",
        "data" => %{
          "id" => "sub_can_1",
          "status" => "canceled",
          "customer_id" => "ctm_x",
          "items" => [%{"price" => %{"id" => "pri_starter_test"}}],
          "current_billing_period" => %{"ends_at" => "2026-07-01T00:00:00Z"}
        }
      }

      assert {:ok, %Subscription{status: "canceled"}} = Billing.upsert_from_paddle_event(event)
    end

    test "subscription.updated for unknown id returns :subscription_not_found" do
      event = %{
        "event_type" => "subscription.updated",
        "data" => %{
          "id" => "sub_does_not_exist",
          "status" => "active",
          "customer_id" => "ctm_x",
          "items" => [%{"price" => %{"id" => "pri_pro_test"}}],
          "current_billing_period" => %{"ends_at" => "2026-07-01T00:00:00Z"}
        }
      }

      assert {:error, :subscription_not_found} = Billing.upsert_from_paddle_event(event)
    end

    test "unknown event types return {:ok, :ignored}" do
      event = %{"event_type" => "transaction.completed", "data" => %{}}
      assert {:ok, :ignored} = Billing.upsert_from_paddle_event(event)
    end
  end
end
