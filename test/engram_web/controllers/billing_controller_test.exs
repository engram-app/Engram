defmodule EngramWeb.BillingControllerTest do
  # async: false — this suite flips the global :billing_enabled app env, which
  # toggles RequireOnboarding on the vault-scoped pipeline. Running concurrently
  # would intermittently gate unrelated async controller tests. Matches the
  # other billing_enabled-flipping suites (onboarding_controller_test, etc.).
  use EngramWeb.ConnCase, async: false

  import Mox

  alias Engram.Accounts

  setup :verify_on_exit!

  # runtime.exs derives billing_enabled from PADDLE_API_KEY (unset in test → false),
  # so enable it explicitly for the Paddle-backed endpoints under test.
  setup do
    prev = Application.get_env(:engram, :billing_enabled)
    Application.put_env(:engram, :billing_enabled, true)
    on_exit(fn -> Application.put_env(:engram, :billing_enabled, prev) end)
    :ok
  end

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, raw_key, _api_key} = Accounts.create_api_key(user, "test")
    grant_api_write!(user)
    conn = put_req_header(conn, "authorization", "Bearer #{raw_key}")
    {:ok, conn: conn, user: user}
  end

  describe "GET /api/billing/status" do
    test "returns free-tier status for new user with no subscription", %{conn: conn} do
      # `active` here means "has a paid (Starter/Pro) subscription" — drives the
      # frontend's `needsSubscription = !billing.active` plan-picker render.
      # Suspension is gated upstream by RequireActiveSubscription; this endpoint
      # only tells the UI whether to show "you're on Free / upgrade" vs the paid
      # billing dashboard.
      conn = get(conn, "/api/billing/status")
      body = json_response(conn, 200)
      assert body["tier"] == "free"
      assert body["active"] == false
      assert body["trial_days_remaining"] == 0
      assert body["subscription"] == nil
      # Bundled connection counts let the cap UI on /link and /oauth/consent
      # decide atCap from a single fetch — a brand-new user has zero of each.
      assert body["current_connections"] == %{"obsidian" => 0, "mcp" => 0}
      # No prior device revoke → no swap cooldown in flight.
      assert body["device_swap_cooldown_remaining_hours"] == nil
    end

    test "returns subscription status for subscribed user", %{conn: conn, user: user} do
      insert(:subscription, user: user, tier: "starter", status: "active")
      conn = get(conn, "/api/billing/status")
      body = json_response(conn, 200)
      assert body["tier"] == "starter"
      assert body["active"] == true
      assert body["subscription"]["status"] == "active"
    end

    test "returns 401 without auth" do
      conn = build_conn() |> get("/api/billing/status")
      assert json_response(conn, 401)
    end

    test "caps reflect free-tier defaults for connection limits", %{conn: conn} do
      # The shared setup grants api_write_enabled=true via grant_api_write!/1
      # (PAT auth precondition), so only obsidian/mcp connection caps still
      # reflect the free-tier default of 1 here.
      conn = get(conn, "/api/billing/status")
      body = json_response(conn, 200)
      assert body["caps"]["obsidian_connections"] == 1
      assert body["caps"]["mcp_connections"] == 1
      assert body["caps"]["api_write_enabled"] == true
    end

    test "explicit UserLimitOverride unlocks unlimited connection caps", %{
      conn: conn,
      user: user
    } do
      # -1 is the canonical "unlimited" sentinel; nil-in-override falls through
      # to plan/tier defaults via wrap_lookup, so it would NOT unlock anything.
      insert(:user_limit_override,
        user: user,
        key: "obsidian_connections_cap",
        value: %{"v" => -1}
      )

      insert(:user_limit_override, user: user, key: "mcp_connections_cap", value: %{"v" => -1})

      conn = get(conn, "/api/billing/status")
      body = json_response(conn, 200)
      assert body["caps"]["obsidian_connections"] == nil
      assert body["caps"]["mcp_connections"] == nil
    end
  end

  describe "GET /api/billing/config" do
    test "returns Paddle.js overlay config for the authenticated user", %{conn: conn, user: user} do
      conn = get(conn, "/api/billing/config")
      body = json_response(conn, 200)

      assert body["client_token"] == "live_token_test_fake"
      assert body["environment"] == "sandbox"
      assert body["price_ids"]["starter"]["monthly"] == "pri_starter_monthly_test"
      assert body["price_ids"]["starter"]["annual"] == "pri_starter_annual_test"
      assert body["price_ids"]["pro"]["monthly"] == "pri_pro_monthly_test"
      assert body["price_ids"]["pro"]["annual"] == "pri_pro_annual_test"
      assert body["customer_email"] == user.email
      assert body["custom_data"]["user_id"] == user.id
    end

    test "exposes the tier-default vaults_cap when the user has no override", %{conn: conn} do
      # limits_enforced is true in test (config/test.exs), so effective_limit
      # resolves the free-tier default for a new user with no subscription:
      # LimitKeys vaults_cap default for :free is 1.
      conn = get(conn, "/api/billing/config")
      body = json_response(conn, 200)
      assert body["vaults_cap"] == 1
    end

    test "exposes an explicit integer vaults_cap override", %{conn: conn, user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 5})
      conn = get(conn, "/api/billing/config")
      body = json_response(conn, 200)
      assert body["vaults_cap"] == 5
    end

    test "stays resilient (200, null cap) when the override value is malformed", %{
      conn: conn,
      user: user
    } do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => "lots"})
      conn = get(conn, "/api/billing/config")
      body = json_response(conn, 200)
      assert body["vaults_cap"] == nil
    end

    test "returns 401 without auth" do
      conn = build_conn() |> get("/api/billing/config")
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/billing/subscription" do
    test "returns normalized detail for a subscribed user", %{conn: conn, user: user} do
      insert(:subscription, user: user, paddle_subscription_id: "sub_dev")

      expect(Engram.Paddle.ClientMock, :get_subscription, fn "sub_dev" ->
        {:ok,
         %{
           "currency_code" => "USD",
           "next_billed_at" => "2026-06-27T07:00:00Z",
           "billing_cycle" => %{"interval" => "month", "frequency" => 1},
           "scheduled_change" => nil,
           "recurring_transaction_details" => %{"totals" => %{"total" => "2000"}}
         }}
      end)

      body = conn |> get("/api/billing/subscription") |> json_response(200)
      assert body["next_billed_at"] == "2026-06-27T07:00:00Z"
      assert body["amount"] == "2000"
      assert body["currency"] == "USD"
      assert body["billing_cycle"] == %{"interval" => "month", "frequency" => 1}
    end

    test "returns 404 when the user has no subscription", %{conn: conn} do
      conn = get(conn, "/api/billing/subscription")
      assert json_response(conn, 404)["error"] == "no subscription"
    end

    test "returns 401 without auth" do
      conn = build_conn() |> get("/api/billing/subscription")
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/billing/transactions" do
    test "returns history and the latest card", %{conn: conn, user: user} do
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
           }
         ]}
      end)

      body = conn |> get("/api/billing/transactions") |> json_response(200)
      assert body["payment_method"]["card_brand"] == "visa"
      assert body["payment_method"]["last4"] == "4242"
      assert [txn] = body["transactions"]
      assert txn["id"] == "txn_2"
      assert txn["amount"] == "2000"
    end

    test "returns 404 when the user has no subscription", %{conn: conn} do
      assert json_response(get(conn, "/api/billing/transactions"), 404)
    end
  end

  describe "GET /api/billing/transactions/:id/invoice" do
    test "returns the invoice URL for the user's own transaction", %{conn: conn, user: user} do
      insert(:subscription, user: user, paddle_subscription_id: "sub_dev")

      expect(Engram.Paddle.ClientMock, :list_transactions, fn "sub_dev" ->
        {:ok, [%{"id" => "txn_2", "payments" => []}]}
      end)

      expect(Engram.Paddle.ClientMock, :get_transaction_invoice, fn "txn_2" ->
        {:ok, "https://paddle.com/invoice/txn_2.pdf"}
      end)

      body = conn |> get("/api/billing/transactions/txn_2/invoice") |> json_response(200)
      assert body["url"] == "https://paddle.com/invoice/txn_2.pdf"
    end

    test "returns 404 for a transaction not belonging to the user", %{conn: conn, user: user} do
      insert(:subscription, user: user, paddle_subscription_id: "sub_dev")

      expect(Engram.Paddle.ClientMock, :list_transactions, fn "sub_dev" ->
        {:ok, [%{"id" => "txn_2", "payments" => []}]}
      end)

      conn = get(conn, "/api/billing/transactions/txn_999/invoice")
      assert json_response(conn, 404)["error"] == "transaction not found"
    end
  end

  describe "GET /api/billing/payment-update-transaction" do
    test "returns the transaction id for the overlay", %{conn: conn, user: user} do
      insert(:subscription, user: user, paddle_subscription_id: "sub_dev")

      expect(Engram.Paddle.ClientMock, :get_update_payment_transaction, fn "sub_dev" ->
        {:ok, %{"id" => "txn_update_1"}}
      end)

      body = conn |> get("/api/billing/payment-update-transaction") |> json_response(200)
      assert body["transaction_id"] == "txn_update_1"
    end

    test "returns 404 when the user has no subscription", %{conn: conn} do
      assert json_response(get(conn, "/api/billing/payment-update-transaction"), 404)
    end
  end

  describe "GET /api/billing/portal?action=" do
    test "returns the cancel deep link", %{conn: conn, user: user} do
      insert(:subscription,
        user: user,
        paddle_customer_id: "ctm_dev",
        paddle_subscription_id: "sub_dev"
      )

      expect(Engram.Paddle.ClientMock, :get_portal_session, fn "ctm_dev" ->
        {:ok,
         %{
           "general" => %{"overview" => "https://p/overview"},
           "subscriptions" => [
             %{"id" => "sub_dev", "cancel_subscription" => "https://p/cancel"}
           ]
         }}
      end)

      body = conn |> get("/api/billing/portal?action=cancel") |> json_response(200)
      assert body["url"] == "https://p/cancel"
    end
  end

  describe "POST /api/billing/cancel-subscription" do
    test "happy path returns 202 with Paddle payload", %{conn: conn, user: user} do
      insert(:subscription, user: user, paddle_subscription_id: "sub_cancel")

      expect(Engram.Paddle.ClientMock, :cancel_subscription, fn "sub_cancel",
                                                                :next_billing_period,
                                                                opts ->
        assert is_binary(Keyword.fetch!(opts, :idempotency_key))
        {:ok, %{"scheduled_change" => %{"effective_at" => "2026-07-01T00:00:00Z"}}}
      end)

      body = conn |> post("/api/billing/cancel-subscription") |> json_response(202)
      assert body["scheduled_change"]["effective_at"] == "2026-07-01T00:00:00Z"
    end

    test "no active sub returns 422", %{conn: conn} do
      body = conn |> post("/api/billing/cancel-subscription") |> json_response(422)
      assert body["error"] == "no_active_subscription"
    end

    test "Paddle error returns 503", %{conn: conn, user: user} do
      insert(:subscription, user: user, paddle_subscription_id: "sub_err")

      expect(Engram.Paddle.ClientMock, :cancel_subscription, fn _, _, _ ->
        {:error, :http_500}
      end)

      body = conn |> post("/api/billing/cancel-subscription") |> json_response(503)
      assert body["error"] == "paddle_unavailable"
    end

    test "Paddle 4xx maps to 422 paddle_rejected with code + detail surfaced from body",
         %{conn: conn, user: user} do
      insert(:subscription, user: user, paddle_subscription_id: "sub_422")

      paddle_body = %{
        "error" => %{
          "code" => "subscription_locked_renewal",
          "detail" => "Subscription is locked because it's currently renewing.",
          "documentation_url" => "https://developer.paddle.com/errors/x"
        }
      }

      expect(Engram.Paddle.ClientMock, :cancel_subscription, fn _, _, _ ->
        {:error, {:paddle_error, 422, paddle_body}}
      end)

      body = conn |> post("/api/billing/cancel-subscription") |> json_response(422)
      assert body["error"] == "paddle_rejected"
      assert body["paddle_status"] == 422
      assert body["paddle_code"] == "subscription_locked_renewal"
      assert body["paddle_detail"] =~ "currently renewing"
    end

    test "Paddle 4xx with no parseable body returns paddle_rejected without code",
         %{conn: conn, user: user} do
      insert(:subscription, user: user, paddle_subscription_id: "sub_422_thin")

      expect(Engram.Paddle.ClientMock, :cancel_subscription, fn _, _, _ ->
        {:error, {:paddle_error, 422, "plain text upstream"}}
      end)

      body = conn |> post("/api/billing/cancel-subscription") |> json_response(422)
      assert body["error"] == "paddle_rejected"
      assert body["paddle_status"] == 422
      refute Map.has_key?(body, "paddle_code")
    end

    test "Paddle 5xx maps to 502 paddle_upstream_error", %{conn: conn, user: user} do
      insert(:subscription, user: user, paddle_subscription_id: "sub_502")

      expect(Engram.Paddle.ClientMock, :cancel_subscription, fn _, _, _ ->
        {:error, {:paddle_error, 502, %{}}}
      end)

      body = conn |> post("/api/billing/cancel-subscription") |> json_response(502)
      assert body["error"] == "paddle_upstream_error"
      assert body["paddle_status"] == 502
    end
  end

  describe "POST /api/billing/reverse-cancel" do
    test "happy path returns 202", %{conn: conn, user: user} do
      insert(:subscription, user: user, paddle_subscription_id: "sub_reverse")

      expect(Engram.Paddle.ClientMock, :update_subscription, fn "sub_reverse", [], opts ->
        assert Keyword.fetch!(opts, :scheduled_change) == nil
        assert is_binary(Keyword.fetch!(opts, :idempotency_key))
        {:ok, %{"scheduled_change" => nil}}
      end)

      body = conn |> post("/api/billing/reverse-cancel") |> json_response(202)
      assert body["scheduled_change"] == nil
    end

    test "no active sub returns 422", %{conn: conn} do
      body = conn |> post("/api/billing/reverse-cancel") |> json_response(422)
      assert body["error"] == "no_active_subscription"
    end
  end

  describe "POST /api/billing/plan-change/preview" do
    test "returns Paddle proration preview shape", %{conn: conn, user: user} do
      insert(:subscription, user: user, paddle_subscription_id: "sub_preview")

      expect(Engram.Paddle.ClientMock, :preview_subscription_update, fn "sub_preview",
                                                                        items,
                                                                        _opts ->
        assert [%{price_id: "pri_pro_monthly_test", quantity: 1}] = items

        {:ok,
         %{
           "old_total" => 1400,
           "new_total" => 700,
           "immediate_charge_or_credit" => -700,
           "next_billed_at" => "2026-07-01T00:00:00Z"
         }}
      end)

      body =
        conn
        |> post("/api/billing/plan-change/preview", %{"target_price_id" => "pri_pro_monthly_test"})
        |> json_response(200)

      assert body["old_total"] == 1400
      assert body["new_total"] == 700
    end

    test "missing target_price_id returns 422", %{conn: conn} do
      body = conn |> post("/api/billing/plan-change/preview", %{}) |> json_response(422)
      assert body["error"] == "target_price_id required"
    end

    test "no active sub returns 422", %{conn: conn} do
      body =
        conn
        |> post("/api/billing/plan-change/preview", %{"target_price_id" => "pri_pro_monthly_test"})
        |> json_response(422)

      assert body["error"] == "no_active_subscription"
    end

    test "off-catalog price_id returns 422 invalid_price_id without hitting Paddle", %{
      conn: conn,
      user: user
    } do
      insert(:subscription, user: user, paddle_subscription_id: "sub_evil")

      # No ClientMock expect — Paddle must NOT be called.
      body =
        conn
        |> post("/api/billing/plan-change/preview", %{"target_price_id" => "pri_arbitrary_zero"})
        |> json_response(422)

      assert body["error"] == "invalid_price_id"
    end
  end

  describe "POST /api/billing/plan-change/confirm" do
    test "happy path returns 202 with Paddle payload", %{conn: conn, user: user} do
      insert(:subscription, user: user, paddle_subscription_id: "sub_confirm")

      expect(Engram.Paddle.ClientMock, :update_subscription, fn "sub_confirm", items, opts ->
        assert [%{price_id: "pri_pro_monthly_test", quantity: 1}] = items
        assert is_binary(Keyword.fetch!(opts, :idempotency_key))
        {:ok, %{"transaction_id" => "txn_xyz"}}
      end)

      body =
        conn
        |> post("/api/billing/plan-change/confirm", %{"target_price_id" => "pri_pro_monthly_test"})
        |> json_response(202)

      assert body["transaction_id"] == "txn_xyz"
    end

    test "Paddle error returns 503", %{conn: conn, user: user} do
      insert(:subscription, user: user, paddle_subscription_id: "sub_confirm_err")

      expect(Engram.Paddle.ClientMock, :update_subscription, fn _, _, _ ->
        {:error, :http_500}
      end)

      body =
        conn
        |> post("/api/billing/plan-change/confirm", %{"target_price_id" => "pri_pro_monthly_test"})
        |> json_response(503)

      assert body["error"] == "paddle_unavailable"
    end
  end
end
