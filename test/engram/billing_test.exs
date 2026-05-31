defmodule Engram.BillingTest do
  use Engram.DataCase, async: true

  import Mox

  alias Engram.Billing
  alias Engram.Billing.LimitKeys
  alias Engram.Billing.Plan
  alias Engram.Billing.PlanCache
  alias Engram.Billing.Subscription
  alias Engram.Repo

  setup :verify_on_exit!

  describe "tier/1" do
    test "returns :free for user with no subscription" do
      user = insert(:user)
      assert Billing.tier(user) == :free
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

    test "returns :free for user with canceled subscription" do
      user = insert(:user)
      insert(:subscription, user: user, tier: "starter", status: "canceled")
      assert Billing.tier(user) == :free
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

  describe "subscription_detail/1" do
    test "normalizes the Paddle subscription for the user" do
      user = insert(:user)
      insert(:subscription, user: user, paddle_subscription_id: "sub_dev")

      expect(Engram.Paddle.ClientMock, :get_subscription, fn "sub_dev" ->
        {:ok,
         %{
           "id" => "sub_dev",
           "status" => "active",
           "currency_code" => "USD",
           "next_billed_at" => "2026-06-27T07:00:00Z",
           "billing_cycle" => %{"interval" => "month", "frequency" => 1},
           "scheduled_change" => nil,
           "recurring_transaction_details" => %{"totals" => %{"total" => "2000"}}
         }}
      end)

      assert {:ok, detail} = Billing.subscription_detail(user)
      assert detail.next_billed_at == "2026-06-27T07:00:00Z"
      assert detail.amount == "2000"
      assert detail.currency == "USD"
      assert detail.billing_cycle == %{interval: "month", frequency: 1}
      assert detail.scheduled_change == nil
    end

    test "surfaces a scheduled cancellation" do
      user = insert(:user)
      insert(:subscription, user: user, paddle_subscription_id: "sub_cancel")

      expect(Engram.Paddle.ClientMock, :get_subscription, fn "sub_cancel" ->
        {:ok,
         %{
           "id" => "sub_cancel",
           "status" => "active",
           "currency_code" => "USD",
           "scheduled_change" => %{
             "action" => "cancel",
             "effective_at" => "2026-06-27T07:00:00Z"
           }
         }}
      end)

      assert {:ok, detail} = Billing.subscription_detail(user)
      assert detail.scheduled_change == %{action: "cancel", effective_at: "2026-06-27T07:00:00Z"}
    end

    test "returns :no_subscription when the user has none" do
      assert {:error, :no_subscription} = Billing.subscription_detail(insert(:user))
    end

    test "propagates client errors" do
      user = insert(:user)
      insert(:subscription, user: user, paddle_subscription_id: "sub_err")

      expect(Engram.Paddle.ClientMock, :get_subscription, fn _ ->
        {:error, {:paddle_error, 500}}
      end)

      assert {:error, {:paddle_error, 500}} = Billing.subscription_detail(user)
    end
  end

  describe "billing_history/1" do
    test "normalizes transactions and extracts the card from the latest payment" do
      user = insert(:user)
      insert(:subscription, user: user, paddle_subscription_id: "sub_dev")

      expect(Engram.Paddle.ClientMock, :list_transactions, fn "sub_dev" ->
        {:ok,
         [
           %{
             "id" => "txn_2",
             "status" => "completed",
             "billed_at" => "2026-05-27T07:00:00Z",
             "invoice_id" => "inv_2",
             "details" => %{"totals" => %{"grand_total" => "2000", "currency_code" => "USD"}},
             "payments" => [
               %{
                 "method_details" => %{
                   "type" => "card",
                   "card" => %{
                     "type" => "visa",
                     "last4" => "4242",
                     "expiry_month" => 12,
                     "expiry_year" => 2027
                   }
                 }
               }
             ]
           },
           %{
             "id" => "txn_1",
             "status" => "completed",
             "billed_at" => "2026-04-27T07:00:00Z",
             "invoice_id" => "inv_1",
             "details" => %{"totals" => %{"grand_total" => "2000", "currency_code" => "USD"}},
             "payments" => []
           }
         ]}
      end)

      assert {:ok, %{payment_method: pm, transactions: txns}} = Billing.billing_history(user)
      assert pm.card_brand == "visa"
      assert pm.last4 == "4242"
      assert pm.exp_month == 12
      assert pm.exp_year == 2027
      assert length(txns) == 2
      assert hd(txns).id == "txn_2"
      assert hd(txns).amount == "2000"
      assert hd(txns).currency == "USD"
      assert hd(txns).status == "completed"
    end

    test "payment_method is nil when no card payment is present" do
      user = insert(:user)
      insert(:subscription, user: user, paddle_subscription_id: "sub_nopm")

      expect(Engram.Paddle.ClientMock, :list_transactions, fn _ ->
        {:ok, [%{"id" => "txn_x", "status" => "completed", "payments" => []}]}
      end)

      assert {:ok, %{payment_method: nil, transactions: [_]}} = Billing.billing_history(user)
    end

    test "returns :no_subscription when the user has none" do
      assert {:error, :no_subscription} = Billing.billing_history(insert(:user))
    end
  end

  describe "transaction_invoice_url/2" do
    test "returns the invoice URL when the transaction belongs to the user" do
      user = insert(:user)
      insert(:subscription, user: user, paddle_subscription_id: "sub_dev")

      expect(Engram.Paddle.ClientMock, :list_transactions, fn "sub_dev" ->
        {:ok, [%{"id" => "txn_2", "payments" => []}, %{"id" => "txn_1", "payments" => []}]}
      end)

      expect(Engram.Paddle.ClientMock, :get_transaction_invoice, fn "txn_2" ->
        {:ok, "https://paddle.com/invoice/txn_2.pdf"}
      end)

      assert {:ok, "https://paddle.com/invoice/txn_2.pdf"} =
               Billing.transaction_invoice_url(user, "txn_2")
    end

    test "rejects a transaction id that does not belong to the user (IDOR guard)" do
      user = insert(:user)
      insert(:subscription, user: user, paddle_subscription_id: "sub_dev")

      expect(Engram.Paddle.ClientMock, :list_transactions, fn "sub_dev" ->
        {:ok, [%{"id" => "txn_2", "payments" => []}]}
      end)

      # get_transaction_invoice must NOT be called for a foreign id.
      assert {:error, :not_found} = Billing.transaction_invoice_url(user, "txn_999")
    end
  end

  describe "portal_action_url/2" do
    setup do
      urls = %{
        "general" => %{"overview" => "https://p/overview"},
        "subscriptions" => [
          %{
            "id" => "sub_dev",
            "cancel_subscription" => "https://p/cancel",
            "update_subscription_payment_method" => "https://p/update"
          }
        ]
      }

      {:ok, urls: urls}
    end

    test "returns the cancel deep link", %{urls: urls} do
      user = insert(:user)

      insert(:subscription,
        user: user,
        paddle_customer_id: "ctm_dev",
        paddle_subscription_id: "sub_dev"
      )

      expect(Engram.Paddle.ClientMock, :get_portal_session, fn "ctm_dev" -> {:ok, urls} end)
      assert {:ok, "https://p/cancel"} = Billing.portal_action_url(user, "cancel")
    end

    test "returns the update-payment deep link", %{urls: urls} do
      user = insert(:user)

      insert(:subscription,
        user: user,
        paddle_customer_id: "ctm_dev",
        paddle_subscription_id: "sub_dev"
      )

      expect(Engram.Paddle.ClientMock, :get_portal_session, fn "ctm_dev" -> {:ok, urls} end)
      assert {:ok, "https://p/update"} = Billing.portal_action_url(user, "update_payment")
    end

    test "falls back to the overview URL for the overview action", %{urls: urls} do
      user = insert(:user)

      insert(:subscription,
        user: user,
        paddle_customer_id: "ctm_dev",
        paddle_subscription_id: "sub_dev"
      )

      expect(Engram.Paddle.ClientMock, :get_portal_session, fn "ctm_dev" -> {:ok, urls} end)
      assert {:ok, "https://p/overview"} = Billing.portal_action_url(user, "overview")
    end

    test "returns :no_subscription when the user has none" do
      assert {:error, :no_subscription} = Billing.portal_action_url(insert(:user), "cancel")
    end
  end

  describe "update_payment_transaction/1" do
    test "returns the Paddle transaction id for the in-app overlay" do
      user = insert(:user)
      insert(:subscription, user: user, paddle_subscription_id: "sub_dev")

      expect(Engram.Paddle.ClientMock, :get_update_payment_transaction, fn "sub_dev" ->
        {:ok, %{"id" => "txn_update_1", "checkout" => %{"url" => "https://pay.paddle.com/x"}}}
      end)

      assert {:ok, "txn_update_1"} = Billing.update_payment_transaction(user)
    end

    test "returns :no_subscription when the user has none" do
      assert {:error, :no_subscription} = Billing.update_payment_transaction(insert(:user))
    end

    test "propagates client errors" do
      user = insert(:user)
      insert(:subscription, user: user, paddle_subscription_id: "sub_err")

      expect(Engram.Paddle.ClientMock, :get_update_payment_transaction, fn _ ->
        {:error, {:paddle_error, 500}}
      end)

      assert {:error, {:paddle_error, 500}} = Billing.update_payment_transaction(user)
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
            %{"price" => %{"id" => "pri_starter_monthly_test"}, "status" => "trialing"}
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
          "items" => [%{"price" => %{"id" => "pri_starter_monthly_test"}}],
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
          "items" => [%{"price" => %{"id" => "pri_pro_monthly_test"}}],
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
          "items" => [%{"price" => %{"id" => "pri_starter_monthly_test"}}],
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
          "items" => [%{"price" => %{"id" => "pri_pro_monthly_test"}}],
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
          "items" => [%{"price" => %{"id" => "pri_starter_monthly_test"}}],
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
          "items" => [%{"price" => %{"id" => "pri_pro_monthly_test"}}],
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

  describe "subscription memoization" do
    test "get_subscription/1 reuses a preloaded :subscription assoc without querying" do
      user = insert(:user)
      insert(:subscription, user: user, tier: "pro", status: "active")
      user = Repo.preload(user, :subscription)

      {result, queries} = with_subscription_query_count(fn -> Billing.get_subscription(user) end)

      assert %Subscription{tier: "pro"} = result
      assert queries == 0
    end

    test "get_subscription/1 returns nil from a preloaded-but-empty assoc without querying" do
      user = insert(:user) |> Repo.preload(:subscription)

      {result, queries} = with_subscription_query_count(fn -> Billing.get_subscription(user) end)

      assert result == nil
      assert queries == 0
    end

    test "active?/1 and tier/1 reuse a preloaded subscription (zero extra queries)" do
      user = insert(:user)
      insert(:subscription, user: user, tier: "pro", status: "active")
      user = Repo.preload(user, :subscription)

      {_, queries} =
        with_subscription_query_count(fn ->
          assert Billing.active?(user)
          assert Billing.tier(user) == :pro
        end)

      assert queries == 0
    end

    test "get_subscription/1 still queries when the assoc is not loaded" do
      user = insert(:user)
      insert(:subscription, user: user, tier: "pro", status: "active")

      {result, queries} = with_subscription_query_count(fn -> Billing.get_subscription(user) end)

      assert %Subscription{} = result
      assert queries == 1
    end
  end

  describe "plan limit caching" do
    setup do
      plan =
        Repo.insert!(%Plan{
          name: "pro_#{System.unique_integer([:positive])}",
          limits: %{"vaults_cap" => 7, "cross_vault_search" => false}
        })

      user = insert(:user) |> Ecto.Changeset.change(plan_id: plan.id) |> Repo.update!()
      on_exit(fn -> PlanCache.invalidate(plan.id) end)
      %{plan: plan, user: user}
    end

    test "resolves plan limits and caches them after the first lookup", %{plan: plan, user: user} do
      PlanCache.invalidate(plan.id)

      {first, q1} =
        with_query_count("plans", fn -> Billing.effective_limit(user, :vaults_cap) end)

      assert first == 7
      assert q1 == 1

      {second, q2} =
        with_query_count("plans", fn -> Billing.effective_limit(user, :vaults_cap) end)

      assert second == 7
      assert q2 == 0
    end

    test "cached lookup preserves false plan values (not treated as missing)", %{user: user} do
      assert Billing.effective_limit(user, :cross_vault_search) == false
      assert Billing.effective_limit(user, :cross_vault_search) == false
    end

    test "missing plan key falls through to the default", %{user: user} do
      # vault_scoped_keys is not set on this plan → default for tier.
      assert Billing.effective_limit(user, :vault_scoped_keys) ==
               LimitKeys.default_for(:vault_scoped_keys, :free)
    end

    test "invalidate/1 forces a re-read", %{plan: plan, user: user} do
      Billing.effective_limit(user, :vaults_cap)
      PlanCache.invalidate(plan.id)

      {_, q} = with_query_count("plans", fn -> Billing.effective_limit(user, :vaults_cap) end)
      assert q == 1
    end

    test "invalidate/1 reflects a runtime limit change (not just a re-query)",
         %{plan: plan, user: user} do
      assert Billing.effective_limit(user, :vaults_cap) == 7

      plan |> Ecto.Changeset.change(limits: %{"vaults_cap" => 99}) |> Repo.update!()
      # Still cached → stale value until invalidated.
      assert Billing.effective_limit(user, :vaults_cap) == 7

      PlanCache.invalidate(plan.id)
      assert Billing.effective_limit(user, :vaults_cap) == 99
    end

    test "invalidate_all/0 drops every cached plan", %{plan: plan, user: user} do
      assert Billing.effective_limit(user, :vaults_cap) == 7

      plan |> Ecto.Changeset.change(limits: %{"vaults_cap" => 42}) |> Repo.update!()
      PlanCache.invalidate_all()

      assert Billing.effective_limit(user, :vaults_cap) == 42
    end

    test "an unknown plan id resolves to an empty limits map (falls to defaults)" do
      missing_id = 2_000_000_000
      PlanCache.invalidate(missing_id)
      assert PlanCache.limits(missing_id) == %{}
    end
  end

  defp with_subscription_query_count(fun), do: with_query_count("subscriptions", fun)

  # Counts Repo queries against `source` emitted while `fun` runs. Telemetry
  # handlers run synchronously in the process that emitted the query, so we
  # scope counting to this test's pid — otherwise concurrent async tests
  # (running in their own processes) leak into the count.
  defp with_query_count(source, fun) do
    test_pid = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      [:engram, :repo, :query],
      fn _event, _measurements, %{source: src}, _config ->
        if src == source and self() == test_pid, do: Agent.update(counter, &(&1 + 1))
      end,
      nil
    )

    try do
      result = fun.()
      {result, Agent.get(counter, & &1)}
    after
      :telemetry.detach(handler_id)
      Agent.stop(counter)
    end
  end
end
