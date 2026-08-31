defmodule Engram.BillingTest do
  # async: false — the "user override caching" tests exercise OverrideCache's
  # node-global ETS table (evict_all/0 in on_exit), and their query-count
  # assertions depend on cache warm/cold state no concurrent module may
  # perturb. (PlanCache's equivalent tests live in Engram.Billing.PlanCacheTest,
  # non-async for the same reason.)
  use Engram.DataCase, async: false

  import Mox

  alias Engram.Billing
  alias Engram.Billing.LimitKeys
  alias Engram.Billing.Subscription
  alias Engram.Repo

  setup :verify_on_exit!

  describe "tier_from_subscription/1" do
    setup do
      # Wipe any per-process dedupe state from previous tests.
      Process.delete(:engram_unknown_price_ids_seen)
      :ok
    end

    test "logs paddle_unknown_price_id once per unknown price per process" do
      paddle_sub_unknown = fn id ->
        %{"items" => [%{"price" => %{"id" => id}}]}
      end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          # Three calls with the same unknown price ID — must log only once.
          # Unknown returns {:error, :unknown_price_id} so the caller can
          # decide what to do (typically: do NOT mutate the user's tier and
          # alert ops) rather than silently coercing to a tier.
          assert {:error, :unknown_price_id} ==
                   Billing.tier_from_subscription(paddle_sub_unknown.("pri_unknown_a"))

          assert {:error, :unknown_price_id} ==
                   Billing.tier_from_subscription(paddle_sub_unknown.("pri_unknown_a"))

          assert {:error, :unknown_price_id} ==
                   Billing.tier_from_subscription(paddle_sub_unknown.("pri_unknown_a"))

          # A different unknown price → should also log once.
          assert {:error, :unknown_price_id} ==
                   Billing.tier_from_subscription(paddle_sub_unknown.("pri_unknown_b"))
        end)

      occurrences = log |> String.split("paddle_unknown_price_id") |> length() |> Kernel.-(1)

      assert occurrences == 2,
             "expected 2 error logs (one per unique unknown id), got #{occurrences}"

      assert log =~ "pri_unknown_a"
      assert log =~ "pri_unknown_b"
    end

    test "does NOT log for known price IDs" do
      starter_id = Application.get_env(:engram, :paddle_starter_monthly_price_id)
      pro_id = Application.get_env(:engram, :paddle_pro_monthly_price_id)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, :starter} ==
                   Billing.tier_from_subscription(%{
                     "items" => [%{"price" => %{"id" => starter_id}}]
                   })

          assert {:ok, :pro} ==
                   Billing.tier_from_subscription(%{"items" => [%{"price" => %{"id" => pro_id}}]})
        end)

      refute log =~ "paddle_unknown_price_id"
    end

    test "returns {:ok, :starter} for starter monthly price id" do
      starter = Application.get_env(:engram, :paddle_starter_monthly_price_id)

      assert {:ok, :starter} =
               Billing.tier_from_subscription(%{"items" => [%{"price" => %{"id" => starter}}]})
    end

    test "returns {:ok, :pro} for pro monthly price id" do
      pro = Application.get_env(:engram, :paddle_pro_monthly_price_id)

      assert {:ok, :pro} =
               Billing.tier_from_subscription(%{"items" => [%{"price" => %{"id" => pro}}]})
    end

    test "returns {:error, :unknown_price_id} for unknown price id" do
      assert {:error, :unknown_price_id} =
               Billing.tier_from_subscription(%{
                 "items" => [%{"price" => %{"id" => "pri_unknown_xyz"}}]
               })
    end

    test "returns {:error, :unknown_price_id} for malformed payload" do
      assert {:error, :unknown_price_id} = Billing.tier_from_subscription(%{})
    end
  end

  describe "tier/1" do
    test "returns :starter when user has active starter subscription" do
      user = build(:user) |> with_subscription(tier: "starter", status: "active")
      assert Billing.tier(user) == :starter
    end

    test "returns :pro when user has active pro subscription" do
      user = build(:user) |> with_subscription(tier: "pro", status: "active")
      assert Billing.tier(user) == :pro
    end

    test "returns :free when no subscription (un-onboarded or self-host)" do
      user = build(:user, free_tier_accepted_at: nil)
      assert Billing.tier(user) == :free
    end

    test "returns :free when free_tier_accepted_at set" do
      user = build(:user, free_tier_accepted_at: DateTime.utc_now())
      assert Billing.tier(user) == :free
    end

    test "returns :free when subscription is canceled" do
      user =
        build(:user, free_tier_accepted_at: DateTime.utc_now())
        |> with_subscription(tier: "pro", status: "canceled")

      assert Billing.tier(user) == :free
    end

    test "returns :pro when subscription is trialing (trial grants the paid tier)" do
      user = build(:user) |> with_subscription(tier: "pro", status: "trialing")
      assert Billing.tier(user) == :pro
    end

    test "returns :starter when subscription is trialing on starter" do
      user = build(:user) |> with_subscription(tier: "starter", status: "trialing")
      assert Billing.tier(user) == :starter
    end

    test "returns :pro when subscription is past_due (grace window keeps access)" do
      user = build(:user) |> with_subscription(tier: "pro", status: "past_due")
      assert Billing.tier(user) == :pro
    end

    test "returns :free when subscription is paused" do
      user = build(:user) |> with_subscription(tier: "pro", status: "paused")
      assert Billing.tier(user) == :free
    end
  end

  describe "plan_state/1" do
    test "free user: all MIME types allowed, numeric caps present" do
      user = build(:user, free_tier_accepted_at: nil)
      state = Billing.plan_state(user)
      assert state.tier == :free
      assert state.attachments_all_types == true
      assert is_integer(state.max_file_bytes)
      assert is_integer(state.attachment_bytes_cap) or is_nil(state.attachment_bytes_cap)
    end

    test "pro user: all attachment types" do
      user = build(:user) |> with_subscription(tier: "pro", status: "active")
      state = Billing.plan_state(user)
      assert state.tier == :pro
      assert state.attachments_all_types == true
    end

    test "the retired legacy field is not published on any tier" do
      # CONTRACT step: `attachments_text_only` was the restriction-shaped
      # spelling, shipped alongside the grant-shaped one so plugin builds
      # predating the rename kept working. The released plugin reads
      # `attachments_all_types` and only falls back when it is absent, so the
      # old field is gone. Asserted rather than merely deleted: silently
      # re-adding it would resurrect the inverted-boolean class that cost
      # self-hosters every image and PDF.
      for user <- [
            build(:user, free_tier_accepted_at: nil),
            build(:user) |> with_subscription(tier: "starter", status: "active"),
            build(:user) |> with_subscription(tier: "pro", status: "active")
          ] do
        state = Billing.plan_state(user)
        assert state.attachments_all_types == true
        refute Map.has_key?(state, :attachments_text_only)
      end
    end
  end

  describe "inactivity_warnings_exempt?/1" do
    test "self-host is exempt: no free-tier dunning on your own server" do
      prev = Application.get_env(:engram, :limits_enforced, true)
      Application.put_env(:engram, :limits_enforced, false)
      on_exit(fn -> Application.put_env(:engram, :limits_enforced, prev) end)

      assert Billing.inactivity_warnings_exempt?(build(:user, free_tier_accepted_at: nil))
    end

    test "Free is not exempt, paid tiers are" do
      refute Billing.inactivity_warnings_exempt?(build(:user, free_tier_accepted_at: nil))

      assert Billing.inactivity_warnings_exempt?(
               build(:user)
               |> with_subscription(tier: "pro", status: "active")
             )
    end

    test "an unreadable override leaves the user ALONE (opposite fail direction)" do
      # Deliberately not fail-closed. Refusing this grant means mailing someone
      # about inactivity and starting the deletion clock, so an unreadable value
      # must not trigger it. Contrast attachments_all_types?/1, where refusing
      # only costs an upload.
      user = insert(:user, free_tier_accepted_at: nil)

      insert(:user_limit_override,
        user: user,
        key: "inactivity_warnings_exempt",
        value: %{"v" => "nonsense"},
        reason: "malformed on purpose",
        set_by: "test"
      )

      assert Billing.inactivity_warnings_exempt?(user)
    end
  end

  describe "the helper and the capabilities map cannot drift" do
    # `capabilities/1` does NOT call attachments_all_types?/1 — it resolves
    # every key generically through normalize_capability/2. That is the split
    # that produced the original bug (plan_state said allowed, capabilities
    # said restricted, and the plugin believed capabilities). Nothing in the
    # types binds the two paths, so this test does.
    for {tier, opts} <- [
          free: [free_tier_accepted_at: nil],
          starter: [subscription: {"starter", "active"}],
          pro: [subscription: {"pro", "active"}]
        ] do
      test "#{tier}: capabilities agrees with the helper" do
        user =
          case unquote(opts)[:subscription] do
            nil -> insert(:user, free_tier_accepted_at: nil)
            {t, s} -> insert(:user) |> with_subscription(tier: t, status: s)
          end

        assert Billing.capabilities(user).limits["attachments_all_types"] ==
                 Billing.attachments_all_types?(user)
      end
    end

    test "and they still agree with enforcement off" do
      prev = Application.get_env(:engram, :limits_enforced, true)
      Application.put_env(:engram, :limits_enforced, false)
      on_exit(fn -> Application.put_env(:engram, :limits_enforced, prev) end)

      user = insert(:user, free_tier_accepted_at: nil)

      assert Billing.capabilities(user).limits["attachments_all_types"] ==
               Billing.attachments_all_types?(user)

      assert Billing.attachments_all_types?(user)
    end
  end

  describe "attachments_all_types?/1 fails closed" do
    test "a malformed override does not grant the paid surface" do
      # Overrides are operator-written JSON. A string "false" instead of the
      # boolean must not read as "not false, therefore granted" — that is the
      # fail-open shape, and the `== true` code this replaced refused it.
      user = insert(:user, free_tier_accepted_at: nil)

      insert(:user_limit_override,
        user: user,
        key: "attachments_all_types",
        value: %{"v" => "false"},
        reason: "malformed on purpose",
        set_by: "test"
      )

      refute Billing.attachments_all_types?(user)
    end

    test "an explicit true override grants" do
      user = insert(:user, free_tier_accepted_at: nil)

      insert(:user_limit_override,
        user: user,
        key: "attachments_all_types",
        value: %{"v" => true},
        reason: "grant",
        set_by: "test"
      )

      assert Billing.attachments_all_types?(user)
    end
  end

  describe "self-host (enforcement off) grants every capability" do
    setup do
      prev = Application.get_env(:engram, :limits_enforced, true)
      Application.put_env(:engram, :limits_enforced, false)
      on_exit(fn -> Application.put_env(:engram, :limits_enforced, prev) end)
      :ok
    end

    test "attachments_all_types? is true even for an otherwise-Free user" do
      # The regression. `attachments_text_only` was restriction-shaped, and
      # `normalize_capability(:boolean, :unlimited)` returns `true` for every
      # boolean — so turning enforcement OFF turned the restriction ON, and
      # self-hosters silently lost every image and PDF while their own server
      # would have accepted them.
      user = build(:user, free_tier_accepted_at: nil)
      assert Billing.attachments_all_types?(user)
    end

    test "plan_state and capabilities agree — they used to disagree" do
      user = insert(:user, free_tier_accepted_at: nil)

      state = Billing.plan_state(user)
      caps = Billing.capabilities(user)

      assert state.attachments_all_types == true
      assert caps.limits["attachments_all_types"] == true
    end

    test "no boolean capability resolves to a restriction" do
      user = insert(:user, free_tier_accepted_at: nil)
      caps = Billing.capabilities(user)

      for key <- LimitKeys.all(), LimitKeys.type(key) == :boolean do
        assert caps.limits[Atom.to_string(key)] == true,
               "#{key} is not granted with enforcement off"
      end
    end
  end

  describe "active?/1 (re-purposed: suspension-only)" do
    test "true for Free user (no subscription, not suspended)" do
      user = build(:user, free_tier_accepted_at: nil, suspended_at: nil)
      assert Billing.active?(user)
    end

    test "true for Pro user (not suspended)" do
      user =
        build(:user, suspended_at: nil)
        |> with_subscription(tier: "pro", status: "active")

      assert Billing.active?(user)
    end

    test "false when suspended" do
      user =
        build(:user,
          free_tier_accepted_at: DateTime.utc_now(),
          suspended_at: DateTime.utc_now()
        )

      refute Billing.active?(user)
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

    test "subscription.created broadcasts subscription_activated on user:{id} topic" do
      user = insert(:user)
      EngramWeb.Endpoint.subscribe("user:#{user.id}")

      event = %{
        "event_type" => "subscription.created",
        "data" => %{
          "id" => "sub_broadcast_1",
          "status" => "trialing",
          "customer_id" => "ctm_broadcast_1",
          "items" => [%{"price" => %{"id" => "pri_starter_monthly_test"}}],
          "current_billing_period" => %{"ends_at" => "2026-07-01T00:00:00Z"},
          "custom_data" => %{"user_id" => user.id}
        }
      }

      assert {:ok, _sub} = Billing.upsert_from_paddle_event(event)

      expected_topic = "user:#{user.id}"

      assert_receive %Phoenix.Socket.Broadcast{
        topic: ^expected_topic,
        event: "subscription_activated",
        payload: payload
      }

      assert payload.status == "trialing"
      assert payload.tier == "starter"
      assert payload.subscription_id == "sub_broadcast_1"

      # Plan snapshot is merged in so the plugin can re-gate attachments the
      # instant the subscription flips, without a follow-up fetch. The fields
      # mirror Billing.plan_state/1 (sans tier, which stays the string form).
      reloaded = Engram.Accounts.get_user(user.id)
      plan = Engram.Billing.plan_state(reloaded)
      assert payload.attachments_all_types == plan.attachments_all_types
      assert payload.max_file_bytes == plan.max_file_bytes
      assert payload.attachment_bytes_cap == plan.attachment_bytes_cap
      assert is_boolean(payload.attachments_all_types)
    end

    test "subscription.updated broadcasts subscription_activated on user:{id} topic" do
      user = insert(:user)

      insert(:subscription,
        user: user,
        paddle_subscription_id: "sub_upd_broadcast_1",
        status: "trialing",
        tier: "starter"
      )

      EngramWeb.Endpoint.subscribe("user:#{user.id}")

      event = %{
        "event_type" => "subscription.activated",
        "data" => %{
          "id" => "sub_upd_broadcast_1",
          "status" => "active",
          "customer_id" => "ctm_x",
          "items" => [%{"price" => %{"id" => "pri_starter_monthly_test"}}],
          "current_billing_period" => %{"ends_at" => "2026-07-01T00:00:00Z"}
        }
      }

      assert {:ok, %Subscription{status: "active"}} = Billing.upsert_from_paddle_event(event)

      expected_topic = "user:#{user.id}"

      assert_receive %Phoenix.Socket.Broadcast{
        topic: ^expected_topic,
        event: "subscription_activated",
        payload: payload
      }

      assert payload.status == "active"
      assert payload.subscription_id == "sub_upd_broadcast_1"
    end

    test "subscription.canceled force-disconnects live sockets" do
      user = insert(:user)

      insert(:subscription,
        user: user,
        paddle_subscription_id: "sub_kick_cancel",
        status: "active",
        tier: "pro"
      )

      topic = "user_socket:#{user.id}"
      EngramWeb.Endpoint.subscribe(topic)

      event = %{
        "event_type" => "subscription.canceled",
        "data" => %{
          "id" => "sub_kick_cancel",
          "status" => "canceled",
          "customer_id" => "ctm_x",
          "items" => [%{"price" => %{"id" => "pri_pro_monthly_test"}}],
          "current_billing_period" => %{"ends_at" => "2026-07-01T00:00:00Z"}
        }
      }

      assert {:ok, _} = Billing.upsert_from_paddle_event(event)

      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
    end

    test "subscription tier downgrade force-disconnects live sockets" do
      user = insert(:user)

      insert(:subscription,
        user: user,
        paddle_subscription_id: "sub_kick_downgrade",
        status: "active",
        tier: "pro"
      )

      topic = "user_socket:#{user.id}"
      EngramWeb.Endpoint.subscribe(topic)

      event = %{
        "event_type" => "subscription.updated",
        "data" => %{
          "id" => "sub_kick_downgrade",
          "status" => "active",
          "customer_id" => "ctm_x",
          "items" => [%{"price" => %{"id" => "pri_starter_monthly_test"}}],
          "current_billing_period" => %{"ends_at" => "2026-07-01T00:00:00Z"}
        }
      }

      assert {:ok, updated} = Billing.upsert_from_paddle_event(event)
      assert updated.tier == "starter"

      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
    end

    test "subscription update with identical tier+status does NOT broadcast disconnect" do
      user = insert(:user)

      insert(:subscription,
        user: user,
        paddle_subscription_id: "sub_noop_update",
        status: "active",
        tier: "pro"
      )

      topic = "user_socket:#{user.id}"
      EngramWeb.Endpoint.subscribe(topic)

      event = %{
        "event_type" => "subscription.updated",
        "data" => %{
          "id" => "sub_noop_update",
          "status" => "active",
          "customer_id" => "ctm_x",
          "items" => [%{"price" => %{"id" => "pri_pro_monthly_test"}}],
          "current_billing_period" => %{"ends_at" => "2026-08-01T00:00:00Z"}
        }
      }

      assert {:ok, _} = Billing.upsert_from_paddle_event(event)

      refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 50
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

    test "tier/1 reuses a preloaded subscription (zero extra queries)" do
      user = insert(:user)
      insert(:subscription, user: user, tier: "pro", status: "active")
      user = Repo.preload(user, :subscription)

      {_, queries} =
        with_subscription_query_count(fn ->
          assert Billing.tier(user) == :pro
        end)

      assert queries == 0
    end

    test "active?/1 issues zero queries (suspension-only, no subscription read)" do
      user = insert(:user)
      insert(:subscription, user: user, tier: "pro", status: "active")

      {_, queries} = with_subscription_query_count(fn -> assert Billing.active?(user) end)

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

  describe "user override caching" do
    alias Engram.Billing.OverrideCache

    setup do
      on_exit(fn -> OverrideCache.evict_all() end)
      %{user: insert(:user)}
    end

    test "caches an override hit after the first lookup", %{user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 9})

      {first, q1} =
        with_query_count("user_limit_overrides", fn ->
          Billing.effective_limit(user, :vaults_cap)
        end)

      assert first == 9
      assert q1 == 1

      {second, q2} =
        with_query_count("user_limit_overrides", fn ->
          Billing.effective_limit(user, :vaults_cap)
        end)

      assert second == 9
      assert q2 == 0
    end

    test "caches the miss — the common case is no override row", %{user: user} do
      {_, q1} =
        with_query_count("user_limit_overrides", fn ->
          Billing.effective_limit(user, :vaults_cap)
        end)

      assert q1 == 1

      {_, q2} =
        with_query_count("user_limit_overrides", fn ->
          Billing.effective_limit(user, :vaults_cap)
        end)

      assert q2 == 0
    end

    test "evict/1 makes a newly granted override visible immediately", %{user: user} do
      default = Billing.effective_limit(user, :vaults_cap)
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 33})

      # The miss is cached — stale default until evicted (or TTL).
      assert Billing.effective_limit(user, :vaults_cap) == default

      :ok = OverrideCache.evict(user.id)
      assert Billing.effective_limit(user, :vaults_cap) == 33
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

  describe "broadcast plan payload" do
    test "carries indexed_notes_cap so a live plugin does not reset it to uncapped" do
      user = insert(:user)
      insert(:subscription, user: user, paddle_subscription_id: "sub_cap_1", status: "active")
      EngramWeb.Endpoint.subscribe("user:#{user.id}")

      # canceled drops the user to :free, so the plan snapshot in this
      # broadcast is the one that must carry the Free index cap. (past_due is
      # deliberately NOT the case to use here — it is in @entitled_statuses.)
      event = %{
        "event_type" => "subscription.canceled",
        "data" => %{
          "id" => "sub_cap_1",
          "status" => "canceled",
          "customer_id" => "ctm_cap_1",
          "items" => [%{"price" => %{"id" => "pri_starter_monthly_test"}}],
          "current_billing_period" => %{"ends_at" => "2026-07-01T00:00:00Z"}
        }
      }

      assert {:ok, _sub} = Billing.upsert_from_paddle_event(event)

      assert_receive %Phoenix.Socket.Broadcast{event: "subscription_activated", payload: payload}

      # The plugin REPLACES its plan snapshot wholesale from this payload, so a
      # missing field reads as "no cap" rather than "unchanged" — a Free user
      # would be told their whole vault is searchable while only the oldest
      # 2,000 notes are indexed.
      assert Map.has_key?(payload, :indexed_notes_cap)

      reloaded = Engram.Accounts.get_user(user.id)
      assert payload.indexed_notes_cap == Engram.Billing.plan_state(reloaded).indexed_notes_cap
      assert payload.indexed_notes_cap == 2_000
    end
  end
end
