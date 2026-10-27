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
    lift_api_rps_cap!(user)
    conn = put_req_header(conn, "authorization", "Bearer #{raw_key}")
    {:ok, conn: conn, user: user}
  end

  # Billing WRITES and capability mints sit behind `RequireSession`, which
  # rejects the API key the default setup uses (and any OAuth grant) — changing
  # what the user pays is not something a delegated credential may do. Those
  # describes re-auth as a first-party session: same user, legitimate
  # credential. So do the PII reads (subscription detail, transactions,
  # invoice). Other read-only billing keeps the API key.
  setup %{conn: conn, user: user} = ctx do
    if ctx[:session_auth] do
      user = ensure_external_id(user)
      {:ok, token} = Engram.Auth.Providers.Local.issue_access_token(user.external_id, user.email)
      {:ok, conn: put_req_header(conn, "authorization", "Bearer #{token}")}
    else
      :ok
    end
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
      # No MCP count: MCP connections are uncapped (#1974).
      assert body["current_connections"] == %{"obsidian" => 0}
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
      # The shared setup lifts api_rps_cap via lift_api_rps_cap!/1; the
      # connection caps still reflect free-tier defaults here. Obsidian is 2 (it tracks
      # concurrent_devices). MCP connections are uncapped (#1974), so the
      # payload carries no MCP cap at all.
      conn = get(conn, "/api/billing/status")
      body = json_response(conn, 200)
      assert body["caps"]["obsidian_connections"] == 2
      refute Map.has_key?(body["caps"], "mcp_connections")
      refute Map.has_key?(body["current_connections"], "mcp")
      refute Map.has_key?(body["caps"], "api_write_enabled")
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

      # A leftover row for the removed `mcp_connections_cap` key (#1974) must
      # be inert: nothing reads it, nothing crashes on it.
      insert(:user_limit_override, user: user, key: "mcp_connections_cap", value: %{"v" => -1})

      conn = get(conn, "/api/billing/status")
      body = json_response(conn, 200)
      assert body["caps"]["obsidian_connections"] == nil
      refute Map.has_key?(body["caps"], "mcp_connections")
    end
  end

  # The /pay page (Paddle's default payment link) opens checkout for a
  # `?_ptxn=` link that arrives in a fresh, often logged-out tab, so the
  # Paddle.js client token must be readable without a session.
  describe "GET /api/billing/paddle-client" do
    test "returns the Paddle.js client token and environment without auth" do
      body = json_response(get(build_conn(), "/api/billing/paddle-client"), 200)
      assert body == %{"client_token" => "live_token_test_fake", "environment" => "sandbox"}
    end

    # CORS echoes the Origin on this path, so a shared cache must never store
    # it (edge-cache-request-varying-headers.md).
    test "is not publicly cacheable" do
      conn = get(build_conn(), "/api/billing/paddle-client")
      refute Enum.any?(get_resp_header(conn, "cache-control"), &(&1 =~ "public"))
    end

    test "404s when billing is disabled (self-host)" do
      Application.put_env(:engram, :billing_enabled, false)
      assert get(build_conn(), "/api/billing/paddle-client").status == 404
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

    # Checkout prefills by Paddle customer id when one exists, so a returning
    # buyer is not split into a second Paddle customer.
    test "exposes the Paddle customer id once the user has one", %{conn: conn, user: user} do
      assert json_response(get(conn, "/api/billing/config"), 200)["customer_id"] == nil

      insert(:subscription, user: user, paddle_customer_id: "ctm_known", status: "canceled")
      Engram.Cache.evict(:subscription, user.id)
      assert json_response(get(conn, "/api/billing/config"), 200)["customer_id"] == "ctm_known"
    end

    test "returns 401 without auth" do
      conn = build_conn() |> get("/api/billing/config")
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/billing/subscription" do
    @describetag :session_auth

    test "returns normalized detail for a subscribed user", %{conn: conn, user: user} do
      insert(:subscription,
        user: user,
        paddle_subscription_id: "sub_dev",
        paddle_customer_id: "ctm_dev"
      )

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

  # "Try again" after an unfinished payment asks this first: a checkout whose
  # money landed while our webhook was still in Paddle's backoff must not open
  # a second checkout (and a second subscription).
  describe "GET /api/billing/checkout-transactions/:id" do
    test "returns the status of the caller's own checkout transaction", %{conn: conn, user: user} do
      expect(Engram.Paddle.ClientMock, :get_transaction, fn "txn_01mine0000000000000000000a" ->
        {:ok,
         %{
           "id" => "txn_01mine0000000000000000000a",
           "status" => "completed",
           "custom_data" => %{"user_id" => user.id}
         }}
      end)

      body =
        conn
        |> get("/api/billing/checkout-transactions/txn_01mine0000000000000000000a")
        |> json_response(200)

      assert body == %{"status" => "completed"}
    end

    test "404s another user's transaction", %{conn: conn} do
      expect(Engram.Paddle.ClientMock, :get_transaction, fn "txn_01theirs00000000000000000a" ->
        {:ok,
         %{
           "id" => "txn_01theirs00000000000000000a",
           "status" => "completed",
           "custom_data" => %{"user_id" => Ecto.UUID.generate()}
         }}
      end)

      conn = get(conn, "/api/billing/checkout-transactions/txn_01theirs00000000000000000a")
      assert json_response(conn, 404)["error"] == "transaction not found"
    end

    # The id goes into the Paddle API path with our server key: anything but
    # Paddle's id pattern (a decoded `/` or `?`) is refused before any call.
    test "400s an id that is not a Paddle transaction id, with no Paddle call", %{conn: conn} do
      expect(Engram.Paddle.ClientMock, :get_transaction, 0, fn _ -> {:ok, %{}} end)

      for id <- [
            "..%2Fcustomers%2Fctm_x",
            "txn_1%3Finclude%3Dcustomer",
            "txn_short",
            "TXN_01AAAAAAAAAAAAAAAAAAAAAAAA"
          ] do
        conn = get(conn, "/api/billing/checkout-transactions/#{id}")
        assert json_response(conn, 400)["error"] == "invalid transaction id"
      end
    end

    # One live Paddle call per request, against a quota the webhooks share.
    test "is rate limited per user", %{conn: conn, user: user} do
      prev = Application.get_env(:engram, :checkout_transaction_rate_limit)
      Application.put_env(:engram, :checkout_transaction_rate_limit, limit: 2, period_ms: 60_000)
      on_exit(fn -> Application.put_env(:engram, :checkout_transaction_rate_limit, prev) end)
      EngramWeb.RateLimiter.reset_buckets!()

      id = "txn_01mine0000000000000000000a"

      expect(Engram.Paddle.ClientMock, :get_transaction, 2, fn ^id ->
        {:ok, %{"id" => id, "status" => "ready", "custom_data" => %{"user_id" => user.id}}}
      end)

      for _ <- 1..2,
          do:
            assert(conn |> get("/api/billing/checkout-transactions/#{id}") |> json_response(200))

      resp = get(conn, "/api/billing/checkout-transactions/#{id}")
      assert json_response(resp, 429)["error"] == "rate_limited"
      assert [_secs] = get_resp_header(resp, "retry-after")
    end

    test "404s a transaction Paddle does not know", %{conn: conn} do
      expect(Engram.Paddle.ClientMock, :get_transaction, fn "txn_01nope0000000000000000000a" ->
        {:error, {:paddle_error, 404, %{"error" => %{"code" => "not_found"}}}}
      end)

      conn = get(conn, "/api/billing/checkout-transactions/txn_01nope0000000000000000000a")
      assert json_response(conn, 404)["error"] == "transaction not found"
    end
  end

  describe "GET /api/billing/transactions" do
    @describetag :session_auth

    test "returns history and the latest card", %{conn: conn, user: user} do
      insert(:subscription,
        user: user,
        paddle_subscription_id: "sub_dev",
        paddle_customer_id: "ctm_dev"
      )

      expect(Engram.Paddle.ClientMock, :list_transactions, fn "ctm_dev" ->
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
    @describetag :session_auth

    test "returns the invoice URL for the user's own transaction", %{conn: conn, user: user} do
      insert(:subscription,
        user: user,
        paddle_subscription_id: "sub_dev",
        paddle_customer_id: "ctm_dev"
      )

      expect(Engram.Paddle.ClientMock, :list_transactions, fn "ctm_dev" ->
        {:ok, [Engram.Fixtures.paddle_transaction("txn_2")]}
      end)

      expect(Engram.Paddle.ClientMock, :get_transaction_invoice, fn "txn_2" ->
        {:ok, "https://paddle.com/invoice/txn_2.pdf"}
      end)

      body = conn |> get("/api/billing/transactions/txn_2/invoice") |> json_response(200)
      assert body["url"] == "https://paddle.com/invoice/txn_2.pdf"
    end

    test "returns 404 for a transaction not belonging to the user", %{conn: conn, user: user} do
      insert(:subscription,
        user: user,
        paddle_subscription_id: "sub_dev",
        paddle_customer_id: "ctm_dev"
      )

      expect(Engram.Paddle.ClientMock, :list_transactions, fn "ctm_dev" ->
        {:ok, [Engram.Fixtures.paddle_transaction("txn_2")]}
      end)

      conn = get(conn, "/api/billing/transactions/txn_999/invoice")
      assert json_response(conn, 404)["error"] == "transaction not found"
    end

    # A $0 trial transaction has no invoice, so Paddle 404s the invoice fetch.
    # That is not a provider outage: 404 to the caller, logged below error
    # level so the billing-error page alert stays quiet.
    test "Paddle 404 on the invoice fetch returns 404 no invoice, not a 502",
         %{conn: conn, user: user} do
      insert(:subscription,
        user: user,
        paddle_subscription_id: "sub_dev",
        paddle_customer_id: "ctm_dev"
      )

      expect(Engram.Paddle.ClientMock, :list_transactions, fn "ctm_dev" ->
        {:ok, [Engram.Fixtures.paddle_transaction("txn_trial")]}
      end)

      expect(Engram.Paddle.ClientMock, :get_transaction_invoice, fn "txn_trial" ->
        {:error, {:paddle_error, 404, %{"error" => %{"code" => "not_found"}}}}
      end)

      log =
        ExUnit.CaptureLog.capture_log([level: :error], fn ->
          conn = get(conn, "/api/billing/transactions/txn_trial/invoice")
          assert json_response(conn, 404)["error"] == "no invoice for this transaction"
        end)

      refute log =~ "Paddle billing error"
    end
  end

  # Only the invoice fetch has an expected 404 (a $0 transaction has no
  # invoice). Every other Paddle 404 addresses an id we stored, so it means our
  # data or config is wrong: it must keep paging billing-error.
  describe "Paddle failures outside the invoice 404" do
    @describetag :session_auth

    test "a non-invoice Paddle 404 still returns 502 and logs at error",
         %{conn: conn, user: user} do
      insert(:subscription, user: user, paddle_subscription_id: "sub_gone")

      expect(Engram.Paddle.ClientMock, :get_update_payment_transaction, fn "sub_gone" ->
        {:error, {:paddle_error, 404, %{}}}
      end)

      log =
        ExUnit.CaptureLog.capture_log([level: :error], fn ->
          conn = get(conn, "/api/billing/payment-update-transaction")
          assert json_response(conn, 502)["error"] == "payment provider error"
        end)

      assert log =~ "Paddle billing error"
    end

    test "a Paddle 5xx on the invoice fetch still returns 502 and logs at error",
         %{conn: conn, user: user} do
      insert(:subscription,
        user: user,
        paddle_subscription_id: "sub_dev",
        paddle_customer_id: "ctm_dev"
      )

      expect(Engram.Paddle.ClientMock, :list_transactions, fn "ctm_dev" ->
        {:ok, [Engram.Fixtures.paddle_transaction("txn_2")]}
      end)

      expect(Engram.Paddle.ClientMock, :get_transaction_invoice, fn "txn_2" ->
        {:error, {:paddle_error, 500, %{}}}
      end)

      log =
        ExUnit.CaptureLog.capture_log([level: :error], fn ->
          conn = get(conn, "/api/billing/transactions/txn_2/invoice")
          assert json_response(conn, 502)["error"] == "payment provider error"
        end)

      assert log =~ "Paddle billing error"
    end
  end

  describe "GET /api/billing/payment-update-transaction" do
    @describetag :session_auth

    test "returns the transaction id for the overlay", %{conn: conn, user: user} do
      insert(:subscription,
        user: user,
        paddle_subscription_id: "sub_dev",
        paddle_customer_id: "ctm_dev"
      )

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
    @describetag :session_auth

    test "answers action=cancel with the overview, not the cancel deep link",
         %{conn: conn, user: user} do
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
      assert body["url"] == "https://p/overview"
    end
  end

  describe "POST /api/billing/cancel-subscription" do
    @describetag :session_auth

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
    @describetag :session_auth

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
    @describetag :session_auth

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
