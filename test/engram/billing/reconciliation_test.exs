defmodule Engram.Billing.ReconciliationTest do
  use Engram.DataCase, async: false

  import Ecto.Query
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
        "items" => [%{"price" => %{"id" => "pri_starter_monthly_test"}}],
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
         [
           paddle_sub(%{
             "id" => "sub_status",
             "customer_id" => "ctm_status",
             "status" => "past_due"
           })
         ]}
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
             "items" => [%{"price" => %{"id" => "pri_pro_monthly_test"}}]
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

      assert %{
               drift: [],
               paddle_total: 0,
               local_total: 0,
               skipped: :billing_disabled,
               error: nil
             } = Reconciliation.run(7)
    end

    test "returns skipped: :fetch_failed with reason when Paddle list_subscriptions errors" do
      Engram.Paddle.ClientMock
      |> expect(:list_subscriptions, fn _since -> {:error, :timeout} end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert %{
                   drift: [],
                   paddle_total: 0,
                   local_total: 0,
                   skipped: :fetch_failed,
                   error: :timeout
                 } = Reconciliation.run(7)
        end)

      assert log =~ "paddle_reconcile_fetch_failed"
      assert log =~ "[error]"
    end

    test "fetch failure logs bounded error_kind + status, never the raw response body" do
      # A Paddle non-2xx surfaces as {:paddle_error, status, body}; the body is
      # echoed Paddle JSON that can carry customer PII. The old code dumped
      # inspect(reason) into the un-redacted :reason metadata key.
      secret = "leaked-customer-XYZZYZ@example.com"

      Engram.Paddle.ClientMock
      |> expect(:list_subscriptions, fn _since ->
        {:error, {:paddle_error, 401, %{"error" => secret}}}
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Reconciliation.run(7)
        end)

      assert log =~ "paddle_reconcile_fetch_failed"
      assert log =~ "error_kind=paddle_error"
      assert log =~ "status=401"
      refute log =~ secret
    end

    test "reports only the highest-priority drift kind when multiple apply (status > tier > period)" do
      user = insert(:user)

      insert(:subscription,
        user: user,
        paddle_subscription_id: "sub_multi",
        paddle_customer_id: "ctm_multi",
        tier: "starter",
        status: "active",
        current_period_end: ~U[2026-06-30 00:00:00Z]
      )

      Engram.Paddle.ClientMock
      |> expect(:list_subscriptions, fn _since ->
        {:ok,
         [
           paddle_sub(%{
             "id" => "sub_multi",
             "customer_id" => "ctm_multi",
             # status drift
             "status" => "past_due",
             # tier drift
             "items" => [%{"price" => %{"id" => "pri_pro_monthly_test"}}],
             # period drift
             "current_billing_period" => %{"ends_at" => "2027-01-01T00:00:00Z"}
           })
         ]}
      end)

      # cond ordering in classify/2 stops at status_mismatch first.
      assert %{drift: [%{kind: :status_mismatch, subscription_id: "sub_multi"}]} =
               Reconciliation.run(7)
    end

    test "surfaces :partial truncation as skipped: :max_pages_exceeded" do
      Engram.Paddle.ClientMock
      |> expect(:list_subscriptions, fn _since ->
        # HTTP layer truncated the list at the page cap.
        {:partial, [paddle_sub(%{"id" => "sub_partial", "customer_id" => "ctm_partial"})],
         :max_pages_exceeded}
      end)

      assert %{
               drift: [%{kind: :missing_local, subscription_id: "sub_partial"}],
               skipped: :max_pages_exceeded,
               paddle_total: 1
             } = Reconciliation.run(7)
    end

    test "surfaces :pagination_loop as skipped: :pagination_loop" do
      Engram.Paddle.ClientMock
      |> expect(:list_subscriptions, fn _since ->
        {:partial, [], :pagination_loop}
      end)

      assert %{skipped: :pagination_loop, paddle_total: 0} = Reconciliation.run(7)
    end

    test "does NOT report :missing_local for an idle local row Paddle just re-ticked" do
      # Regression: local was created long ago (updated_at older than the
      # reconciliation window) but Paddle re-emitted it (their `updated_at`
      # advanced — e.g. scheduled_change processing). Lookup by
      # paddle_subscription_id, not local updated_at, so the match holds.
      user = insert(:user)

      sub =
        insert(:subscription,
          user: user,
          paddle_subscription_id: "sub_idle_local",
          paddle_customer_id: "ctm_idle_local",
          tier: "starter",
          status: "active",
          current_period_end: ~U[2026-06-30 00:00:00Z]
        )

      # Backdate local updated_at to 30 days ago — well outside the 7-day window.
      stale_at = DateTime.utc_now() |> DateTime.add(-30 * 86_400, :second)

      Engram.Repo.update_all(
        from(s in Engram.Billing.Subscription, where: s.id == ^sub.id),
        [set: [updated_at: stale_at]],
        skip_tenant_check: true
      )

      Engram.Paddle.ClientMock
      |> expect(:list_subscriptions, fn _since ->
        {:ok, [paddle_sub(%{"id" => "sub_idle_local", "customer_id" => "ctm_idle_local"})]}
      end)

      assert %{drift: [], paddle_total: 1, local_total: 1} = Reconciliation.run(7)
    end

    test "tolerates period skew in both directions (symmetric ±2 minutes)" do
      user = insert(:user)

      insert(:subscription,
        user: user,
        paddle_subscription_id: "sub_skew_back",
        paddle_customer_id: "ctm_skew_back",
        tier: "starter",
        status: "active",
        current_period_end: ~U[2026-06-30 00:00:00Z]
      )

      Engram.Paddle.ClientMock
      |> expect(:list_subscriptions, fn _since ->
        {:ok,
         [
           paddle_sub(%{
             "id" => "sub_skew_back",
             "customer_id" => "ctm_skew_back",
             # 1 minute EARLIER — also within tolerance (abs())
             "current_billing_period" => %{"ends_at" => "2026-06-29T23:59:00Z"}
           })
         ]}
      end)

      assert %{drift: []} = Reconciliation.run(7)
    end
  end
end
