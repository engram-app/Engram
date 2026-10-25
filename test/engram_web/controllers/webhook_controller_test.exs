defmodule EngramWeb.WebhookControllerTest do
  use EngramWeb.ConnCase, async: true
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query

  describe "POST /webhooks/paddle" do
    test "returns 400 when signature is missing", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/paddle", "{}")

      assert json_response(conn, 400)["error"] == "missing paddle-signature header"
    end

    test "returns 400 when signature is invalid", %{conn: conn} do
      timestamp = System.system_time(:second)
      sig_header = "ts=#{timestamp};h1=deadbeef"

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("paddle-signature", sig_header)
        |> post("/webhooks/paddle", ~s({"event_type":"transaction.completed"}))

      assert json_response(conn, 400)["error"] =~ "signature"
    end

    test "returns 400 for replayed signature with old timestamp", %{conn: conn} do
      payload = ~s({"event_type":"transaction.completed","data":{}})
      # 6 minutes ago — outside the 300-second window
      timestamp = System.system_time(:second) - 360
      signature = sign(timestamp, payload)
      sig_header = "ts=#{timestamp};h1=#{signature}"

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("paddle-signature", sig_header)
        |> post("/webhooks/paddle", payload)

      assert json_response(conn, 400)["error"] =~ "old"
    end

    test "returns 200 and upserts subscription on valid subscription.created", %{conn: conn} do
      user = insert(:user)

      payload =
        Jason.encode!(%{
          "event_type" => "subscription.created",
          "event_id" => "ntf_wh_create",
          "data" => %{
            "id" => "sub_wh_create",
            "status" => "trialing",
            "customer_id" => "ctm_wh_create",
            "items" => [%{"price" => %{"id" => "pri_starter_monthly_test"}}],
            "current_billing_period" => %{"ends_at" => "2026-05-20T00:00:00Z"},
            "custom_data" => %{"user_id" => user.id, "affiliate_ref" => "rf_1"}
          }
        })

      timestamp = System.system_time(:second)
      signature = sign(timestamp, payload)
      sig_header = "ts=#{timestamp};h1=#{signature}"

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("paddle-signature", sig_header)
        |> post("/webhooks/paddle", payload)

      assert json_response(conn, 200)["status"] == "ok"

      sub = Engram.Billing.get_subscription(user)
      assert sub.paddle_customer_id == "ctm_wh_create"
      assert sub.paddle_subscription_id == "sub_wh_create"
      assert sub.tier == "starter"
      assert sub.status == "trialing"
      assert sub.custom_data["affiliate_ref"] == "rf_1"
    end

    test "returns 200 for unhandled event types", %{conn: conn} do
      payload = Jason.encode!(%{"event_type" => "transaction.paid", "data" => %{}})
      timestamp = System.system_time(:second)
      signature = sign(timestamp, payload)
      sig_header = "ts=#{timestamp};h1=#{signature}"

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("paddle-signature", sig_header)
        |> post("/webhooks/paddle", payload)

      assert json_response(conn, 200)["status"] == "ok"
    end

    test "returns 400 for future-dated timestamp (clock-skew replay defense)", %{conn: conn} do
      payload = ~s({"event_type":"transaction.completed","data":{}})
      # 6 minutes in the FUTURE — beyond the 300s window
      timestamp = System.system_time(:second) + 360
      signature = sign(timestamp, payload)
      sig_header = "ts=#{timestamp};h1=#{signature}"

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("paddle-signature", sig_header)
        |> post("/webhooks/paddle", payload)

      assert json_response(conn, 400)["error"] =~ "old"
    end

    test "subscription.created is idempotent: same event delivered twice yields one row", %{
      conn: _conn
    } do
      user = insert(:user)

      payload =
        Jason.encode!(%{
          "event_type" => "subscription.created",
          "event_id" => "ntf_idempotent",
          "data" => %{
            "id" => "sub_idempotent",
            "status" => "trialing",
            "customer_id" => "ctm_idempotent",
            "items" => [%{"price" => %{"id" => "pri_starter_monthly_test"}}],
            "current_billing_period" => %{"ends_at" => "2026-05-20T00:00:00Z"},
            "custom_data" => %{"user_id" => user.id, "affiliate_ref" => "rf_first"}
          }
        })

      send_signed = fn ->
        timestamp = System.system_time(:second)
        signature = sign(timestamp, payload)

        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("paddle-signature", "ts=#{timestamp};h1=#{signature}")
        |> post("/webhooks/paddle", payload)
      end

      assert json_response(send_signed.(), 200)["status"] == "ok"
      assert json_response(send_signed.(), 200)["status"] == "ok"

      rows =
        Engram.Repo.all(
          from(s in Engram.Billing.Subscription, where: s.user_id == ^user.id),
          skip_tenant_check: true
        )

      assert length(rows) == 1
    end

    test "subscription.created retry preserves custom_data from first delivery", %{conn: _conn} do
      user = insert(:user)

      payload_1 = build_created_payload(user, "rf_first")
      payload_2 = build_created_payload(user, "rf_overwrite")

      send_payload(payload_1)
      send_payload(payload_2)

      sub = Engram.Billing.get_subscription(user)
      assert sub.custom_data["affiliate_ref"] == "rf_first"
    end

    test "a replayed event_id short-circuits before the handler runs", %{conn: _conn} do
      user = insert(:user)
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :paddle, :webhook, :stop]])

      payload =
        Jason.encode!(%{
          "event_type" => "subscription.created",
          "event_id" => "ntf_replay_once",
          "data" => %{
            "id" => "sub_replay_once",
            "status" => "trialing",
            "customer_id" => "ctm_replay_once",
            "items" => [%{"price" => %{"id" => "pri_starter_monthly_test"}}],
            "current_billing_period" => %{"ends_at" => "2026-05-20T00:00:00Z"},
            "custom_data" => %{"user_id" => user.id}
          }
        })

      send_signed = fn ->
        ts = System.system_time(:second)

        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("paddle-signature", "ts=#{ts};h1=#{sign(ts, payload)}")
        |> post("/webhooks/paddle", payload)
      end

      assert json_response(send_signed.(), 200)["status"] == "ok"
      assert json_response(send_signed.(), 200)["status"] == "ok"

      # The handler span fires exactly once — the replay was deduped before it.
      assert_received {[:engram, :paddle, :webhook, :stop], ^ref, _,
                       %{event_id: "ntf_replay_once"}}

      refute_received {[:engram, :paddle, :webhook, :stop], ^ref, _, _}
    end

    test "subscription.canceled before subscription.created creates the row from custom_data",
         %{conn: conn} do
      user = insert(:user)

      payload =
        Jason.encode!(%{
          "event_type" => "subscription.canceled",
          "event_id" => "ntf_orphan_cancel",
          "data" => %{
            "id" => "sub_never_created",
            "status" => "canceled",
            "customer_id" => "ctm_never_created",
            "items" => [%{"price" => %{"id" => "pri_starter_monthly_test"}}],
            "current_billing_period" => %{"ends_at" => "2026-05-20T00:00:00Z"},
            "custom_data" => %{"user_id" => user.id}
          }
        })

      timestamp = System.system_time(:second)
      signature = sign(timestamp, payload)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("paddle-signature", "ts=#{timestamp};h1=#{signature}")
        |> post("/webhooks/paddle", payload)

      assert json_response(conn, 200)["status"] == "ok"

      assert %{status: "canceled", paddle_subscription_id: "sub_never_created"} =
               Engram.Billing.get_subscription(user)

      assert Engram.Billing.tier(Engram.Repo.reload(user)) == :free
    end

    test "subscription.activated event updates an existing subscription", %{conn: _conn} do
      user = insert(:user)

      _ =
        send_payload(
          Jason.encode!(%{
            "event_type" => "subscription.created",
            "event_id" => "ntf_a1",
            "data" => %{
              "id" => "sub_activated",
              "status" => "trialing",
              "customer_id" => "ctm_a",
              "items" => [%{"price" => %{"id" => "pri_starter_monthly_test"}}],
              "current_billing_period" => %{"ends_at" => "2026-05-20T00:00:00Z"},
              "custom_data" => %{"user_id" => user.id}
            }
          })
        )

      _ =
        send_payload(
          Jason.encode!(%{
            "event_type" => "subscription.activated",
            "event_id" => "ntf_a2",
            "data" => %{
              "id" => "sub_activated",
              "status" => "active",
              "items" => [%{"price" => %{"id" => "pri_starter_monthly_test"}}],
              "current_billing_period" => %{"ends_at" => "2026-06-20T00:00:00Z"}
            }
          })
        )

      sub = Engram.Billing.get_subscription(user)
      assert sub.status == "active"
    end

    test "emits :telemetry.span events on success", %{conn: conn} do
      user = insert(:user)

      ref =
        :telemetry_test.attach_event_handlers(
          self(),
          [
            [:engram, :paddle, :webhook, :start],
            [:engram, :paddle, :webhook, :stop]
          ]
        )

      payload =
        Jason.encode!(%{
          "event_type" => "subscription.created",
          "event_id" => "ntf_wh_telemetry",
          "data" => %{
            "id" => "sub_wh_telemetry",
            "status" => "trialing",
            "customer_id" => "ctm_wh_telemetry",
            "items" => [%{"price" => %{"id" => "pri_starter_monthly_test"}}],
            "current_billing_period" => %{"ends_at" => "2026-05-20T00:00:00Z"},
            "custom_data" => %{"user_id" => user.id}
          }
        })

      ts = System.system_time(:second)
      sig_header = "ts=#{ts};h1=#{sign(ts, payload)}"

      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("paddle-signature", sig_header)
      |> post("/webhooks/paddle", payload)

      assert_received {[:engram, :paddle, :webhook, :start], ^ref, _measurements,
                       %{event_type: "subscription.created", event_id: "ntf_wh_telemetry"}}

      assert_received {[:engram, :paddle, :webhook, :stop], ^ref, %{duration: _},
                       %{
                         event_type: "subscription.created",
                         event_id: "ntf_wh_telemetry",
                         result: :ok
                       }}
    end

    test "emits :telemetry.span with result: :error on handler failure", %{conn: conn} do
      ref =
        :telemetry_test.attach_event_handlers(
          self(),
          [[:engram, :paddle, :webhook, :stop]]
        )

      payload =
        Jason.encode!(%{
          "event_type" => "subscription.created",
          "event_id" => "ntf_err_result",
          "data" => %{
            "id" => "sub_err_result",
            "status" => "trialing",
            "customer_id" => "ctm_err_result",
            "items" => [%{"price" => %{"id" => "pri_starter_monthly_test"}}],
            "current_billing_period" => %{"ends_at" => "2026-05-20T00:00:00Z"},
            # Missing user_id → Billing.upsert_from_paddle_event/1 returns
            # {:error, :missing_user_id} → :stop fires with result: :error.
            "custom_data" => %{}
          }
        })

      ts = System.system_time(:second)
      sig_header = "ts=#{ts};h1=#{sign(ts, payload)}"

      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("paddle-signature", sig_header)
      |> post("/webhooks/paddle", payload)

      assert_received {[:engram, :paddle, :webhook, :stop], ^ref, %{duration: _},
                       %{event_id: "ntf_err_result", result: :error}}
    end

    test "subscription.canceled flips user to Free tier and emits :tier_downgraded telemetry",
         %{conn: conn} do
      user = insert(:user, free_tier_accepted_at: nil)

      insert(:subscription,
        user: user,
        paddle_subscription_id: "sub_xyz",
        status: "active",
        tier: "pro"
      )

      pro_price_id = Application.fetch_env!(:engram, :paddle_pro_monthly_price_id)

      ref =
        :telemetry_test.attach_event_handlers(
          self(),
          [[:engram, :tier_downgraded]]
        )

      payload =
        Jason.encode!(%{
          "event_type" => "subscription.canceled",
          "event_id" => "ntf_cancel_free_tier",
          "data" => %{
            "id" => "sub_xyz",
            "status" => "canceled",
            "customer_id" => "ctm_x",
            "items" => [%{"price" => %{"id" => pro_price_id}}],
            "current_billing_period" => %{"ends_at" => "2026-07-01T00:00:00Z"}
          }
        })

      timestamp = System.system_time(:second)
      signature = sign(timestamp, payload)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("paddle-signature", "ts=#{timestamp};h1=#{signature}")
        |> post("/webhooks/paddle", payload)

      assert json_response(conn, 200)["status"] == "ok"

      reloaded_user = Engram.Repo.reload(user)
      assert reloaded_user.free_tier_accepted_at != nil

      sub = Engram.Billing.get_subscription(reloaded_user)
      assert sub.status == "canceled"

      assert_received {[:engram, :tier_downgraded], ^ref, _meas,
                       %{from: :pro, to: :free, user_id: _}}

      # No index-cap sweep any more: Free has no search-coverage cap, so a
      # downgrade leaves every note searchable.
      refute_enqueued(worker: Engram.Workers.IndexCapMaintenance)
    end

    test "subscription.canceled preserves free_tier_accepted_at when already set",
         %{conn: conn} do
      original_ts = DateTime.add(DateTime.utc_now(), -86_400, :second)
      user = insert(:user, free_tier_accepted_at: original_ts)

      insert(:subscription,
        user: user,
        paddle_subscription_id: "sub_preserve",
        status: "active",
        tier: "pro"
      )

      pro_price_id = Application.fetch_env!(:engram, :paddle_pro_monthly_price_id)

      payload =
        Jason.encode!(%{
          "event_type" => "subscription.canceled",
          "event_id" => "ntf_cancel_preserve",
          "data" => %{
            "id" => "sub_preserve",
            "status" => "canceled",
            "customer_id" => "ctm_x",
            "items" => [%{"price" => %{"id" => pro_price_id}}],
            "current_billing_period" => %{"ends_at" => "2026-07-01T00:00:00Z"}
          }
        })

      timestamp = System.system_time(:second)
      signature = sign(timestamp, payload)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("paddle-signature", "ts=#{timestamp};h1=#{signature}")
        |> post("/webhooks/paddle", payload)

      assert json_response(conn, 200)["status"] == "ok"

      reloaded_user = Engram.Repo.reload(user)
      assert DateTime.compare(reloaded_user.free_tier_accepted_at, original_ts) == :eq
    end

    test "subscription.created with missing custom_data.user_id returns 200 and creates no row",
         %{conn: conn} do
      payload =
        Jason.encode!(%{
          "event_type" => "subscription.created",
          "event_id" => "ntf_no_user",
          "data" => %{
            "id" => "sub_orphan",
            "status" => "trialing",
            "customer_id" => "ctm_orphan",
            "items" => [%{"price" => %{"id" => "pri_starter_monthly_test"}}],
            "current_billing_period" => %{"ends_at" => "2026-05-20T00:00:00Z"},
            "custom_data" => %{}
          }
        })

      timestamp = System.system_time(:second)
      signature = sign(timestamp, payload)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("paddle-signature", "ts=#{timestamp};h1=#{signature}")
        |> post("/webhooks/paddle", payload)

      assert json_response(conn, 200)["status"] == "ok"

      refute Engram.Repo.exists?(
               from(s in Engram.Billing.Subscription,
                 where: s.paddle_subscription_id == "sub_orphan"
               ),
               skip_tenant_check: true
             )
    end
  end

  describe "POST /webhooks/paddle: retries, ordering, first-event upsert" do
    test "a transient DB failure returns 500, is not marked processed, and the retry succeeds" do
      user = insert(:user)
      # A real DB error on write. DDL inside the sandbox transaction rolls back
      # with the test, so no other test sees the trigger.
      Engram.Repo.query!("""
      CREATE FUNCTION pg_temp.fail_sub_write() RETURNS trigger AS $$
      BEGIN RAISE EXCEPTION 'simulated outage'; END $$ LANGUAGE plpgsql
      """)

      Engram.Repo.query!("""
      CREATE TRIGGER fail_sub_write BEFORE INSERT OR UPDATE ON subscriptions
      FOR EACH ROW EXECUTE FUNCTION pg_temp.fail_sub_write()
      """)

      payload =
        sub_event("subscription.created", "ntf_transient", "sub_transient", user, "active")

      assert json_response(send_payload(payload), 500)["status"] == "error"
      assert Engram.Webhooks.Idempotency.check(:paddle, "ntf_transient") == :proceed

      Engram.Repo.query!("DROP TRIGGER fail_sub_write ON subscriptions")

      assert json_response(send_payload(payload), 200)["status"] == "ok"
      assert %{status: "active"} = Engram.Billing.get_subscription(user)
      assert Engram.Webhooks.Idempotency.check(:paddle, "ntf_transient") == :duplicate
    end

    test "a permanent bad payload (no custom_data.user_id) answers 200 so Paddle stops" do
      payload =
        Jason.encode!(%{
          "event_type" => "subscription.created",
          "event_id" => "ntf_no_owner",
          "data" => %{
            "id" => "sub_no_owner",
            "status" => "active",
            "customer_id" => "ctm_no_owner",
            "items" => [%{"price" => %{"id" => "pri_pro_monthly_test"}}],
            "custom_data" => %{}
          }
        })

      assert json_response(send_payload(payload), 200)["status"] == "ok"
    end

    test "a delayed subscription.updated older than the stored cancel is skipped" do
      user = insert(:user)

      send_payload(
        sub_event("subscription.created", "ntf_o1", "sub_order", user, "active",
          occurred_at: "2026-10-01T00:00:00.000001Z"
        )
      )

      send_payload(
        sub_event("subscription.canceled", "ntf_o3", "sub_order", user, "canceled",
          occurred_at: "2026-10-03T00:00:00.000001Z"
        )
      )

      # Occurred between the two above, delivered last.
      conn =
        send_payload(
          sub_event("subscription.updated", "ntf_o2", "sub_order", user, "active",
            occurred_at: "2026-10-02T00:00:00.000001Z"
          )
        )

      assert json_response(conn, 200)["status"] == "ok"
      assert %{status: "canceled"} = Engram.Billing.get_subscription(user)
      assert Engram.Billing.tier(Engram.Repo.reload(user)) == :free
    end

    test "a stale subscription.created retry does not undo a newer update" do
      user = insert(:user)

      send_payload(
        sub_event("subscription.updated", "ntf_c2", "sub_cretry", user, "past_due",
          occurred_at: "2026-10-02T00:00:00Z"
        )
      )

      send_payload(
        sub_event("subscription.created", "ntf_c1", "sub_cretry", user, "active",
          occurred_at: "2026-10-01T00:00:00Z"
        )
      )

      assert %{status: "past_due"} = Engram.Billing.get_subscription(user)
    end

    test "subscription.updated before subscription.created creates the row and grants the tier" do
      user = insert(:user)

      conn =
        send_payload(
          sub_event("subscription.updated", "ntf_first_upd", "sub_first", user, "active")
        )

      assert json_response(conn, 200)["status"] == "ok"

      assert %{status: "active", tier: "pro", paddle_customer_id: "ctm_sub_first"} =
               Engram.Billing.get_subscription(user)

      assert Engram.Billing.tier(Engram.Repo.reload(user)) == :pro
    end

    test "a first event for an OLD subscription does not replace the user's live one" do
      user = insert(:user)
      send_payload(sub_event("subscription.created", "ntf_new", "sub_new", user, "active"))

      # The previous subscription's cancel, never seen before (its row was
      # replaced by the resubscribe), arrives afterwards.
      conn =
        send_payload(sub_event("subscription.canceled", "ntf_old", "sub_old", user, "canceled"))

      assert json_response(conn, 200)["status"] == "ok"

      assert %{paddle_subscription_id: "sub_new", status: "active"} =
               Engram.Billing.get_subscription(user)
    end

    test "non-trial first checkout: created(active) + transaction.completed grants the tier" do
      user = insert(:user)

      created =
        sub_event("subscription.created", "ntf_paid_1", "sub_paid", user, "active",
          occurred_at: "2026-10-24T10:00:00.000001Z"
        )

      completed =
        Jason.encode!(%{
          "event_type" => "transaction.completed",
          "event_id" => "ntf_paid_2",
          "occurred_at" => "2026-10-24T10:00:01.000001Z",
          "data" => %{
            "id" => "txn_paid",
            "status" => "completed",
            "origin" => "web",
            "customer_id" => "ctm_sub_paid",
            "subscription_id" => "sub_paid",
            "details" => %{"totals" => %{"total" => "1000", "grand_total" => "1000"}},
            "custom_data" => %{"user_id" => user.id}
          }
        })

      assert json_response(send_payload(created), 200)["status"] == "ok"
      assert json_response(send_payload(completed), 200)["status"] == "ok"

      assert %{status: "active", tier: "pro"} = Engram.Billing.get_subscription(user)
      assert Engram.Billing.tier(Engram.Repo.reload(user)) == :pro
    end
  end

  describe "POST /webhooks/paddle: owner deleted" do
    # Hard delete cancels at Paddle, then cascades the row. Paddle's follow-up
    # events still name the deleted user: an FK raise would 500 them for days.
    test "an event for a deleted user answers 200, is marked processed, and reports nothing" do
      Sentry.Test.setup_sentry()
      user = insert(:user)
      insert(:subscription, user: user, paddle_subscription_id: "sub_gone")
      Engram.Repo.delete!(user, skip_tenant_check: true)

      for {type, id} <- [
            {"subscription.canceled", "ntf_gone_1"},
            {"subscription.created", "ntf_gone_2"}
          ] do
        conn = send_payload(sub_event(type, id, "sub_gone", user, "canceled"))
        assert json_response(conn, 200)["status"] == "ok"
        assert Engram.Webhooks.Idempotency.check(:paddle, id) == :duplicate
      end

      assert Sentry.Test.pop_sentry_reports() == []
    end
  end

  describe "POST /webhooks/paddle: refund cancel rejected by Paddle" do
    test "answers 200 so Paddle stops retrying a cancel it will never accept" do
      import Mox
      user = insert(:user)

      insert(:subscription,
        user: user,
        paddle_subscription_id: "sub_rej",
        paddle_customer_id: "ctm_rej",
        status: "active"
      )

      expect(Engram.Paddle.ClientMock, :list_transactions, fn _ ->
        {:ok,
         [
           %{
             "id" => "txn_rej",
             "status" => "completed",
             "subscription_id" => "sub_rej",
             "billed_at" => "2026-10-01T00:00:00Z",
             "details" => %{"totals" => %{"grand_total" => "1500"}}
           }
         ]}
      end)

      expect(Engram.Paddle.ClientMock, :cancel_subscription, fn _, _, _ ->
        {:error, {:paddle_error, 422, %{}}}
      end)

      expect(Engram.Paddle.ClientMock, :get_subscription, fn _ ->
        {:ok, %{"id" => "sub_rej", "status" => "active"}}
      end)

      payload =
        Jason.encode!(%{
          "event_type" => "adjustment.updated",
          "event_id" => "ntf_rej",
          "data" => %{
            "id" => "adj_rej",
            "action" => "refund",
            "type" => "full",
            "status" => "approved",
            "subscription_id" => "sub_rej",
            "transaction_id" => "txn_rej"
          }
        })

      assert json_response(send_payload(payload), 200)["status"] == "ok"
    end
  end

  describe "POST /webhooks/paddle: late created for an old subscription" do
    test "a redelivered created for the OLD subscription does not replace the live new one" do
      user = insert(:user)

      for {id, sub, at} <- [
            {"ntf_s1", "sub_s1", "2026-10-01T00:00:00Z"},
            {"ntf_s2", "sub_s2", "2026-10-05T00:00:00Z"}
          ] do
        send_payload(sub_event("subscription.created", id, sub, user, "active", occurred_at: at))
      end

      # Paddle's retry of S1's created, after a 500, lands last.
      conn =
        send_payload(
          sub_event("subscription.created", "ntf_s1_retry", "sub_s1", user, "active",
            occurred_at: "2026-10-01T00:00:00Z"
          )
        )

      assert json_response(conn, 200)["status"] == "ok"
      assert Engram.Webhooks.Idempotency.check(:paddle, "ntf_s1_retry") == :duplicate
      assert %{paddle_subscription_id: "sub_s2"} = Engram.Billing.get_subscription(user)
    end

    # A NEW subscription's update can beat its own created while the old row
    # is still live. Acking it would lose it; a 500 lets Paddle retry it once
    # the created has landed.
    test "an update for a subscription newer than the live row waits for its created" do
      user = insert(:user)

      send_payload(
        sub_event("subscription.created", "ntf_w1", "sub_w_old", user, "active",
          occurred_at: "2026-10-01T00:00:00Z"
        )
      )

      early_update =
        sub_event("subscription.updated", "ntf_w3", "sub_w_new", user, "past_due",
          occurred_at: "2026-10-06T00:00:00Z",
          created_at: "2026-10-05T00:00:00Z"
        )

      assert json_response(send_payload(early_update), 500)["status"] == "error"
      assert Engram.Webhooks.Idempotency.check(:paddle, "ntf_w3") == :proceed

      send_payload(
        sub_event("subscription.created", "ntf_w2", "sub_w_new", user, "active",
          occurred_at: "2026-10-05T00:00:00Z",
          created_at: "2026-10-05T00:00:00Z"
        )
      )

      assert json_response(send_payload(early_update), 200)["status"] == "ok"

      assert %{paddle_subscription_id: "sub_w_new", status: "past_due"} =
               Engram.Billing.get_subscription(user)
    end

    test "a late event for an OLD subscription (created before the live row) is acked" do
      user = insert(:user)

      send_payload(
        sub_event("subscription.created", "ntf_l1", "sub_l_new", user, "active",
          occurred_at: "2026-10-05T00:00:00Z"
        )
      )

      conn =
        send_payload(
          sub_event("subscription.canceled", "ntf_l2", "sub_l_old", user, "canceled",
            occurred_at: "2026-10-06T00:00:00Z",
            created_at: "2026-09-01T00:00:00Z"
          )
        )

      assert json_response(conn, 200)["status"] == "ok"
      assert %{paddle_subscription_id: "sub_l_new"} = Engram.Billing.get_subscription(user)
    end

    test "a resubscribe after a cancel still replaces the row" do
      user = insert(:user)

      send_payload(
        sub_event("subscription.canceled", "ntf_r1", "sub_r1", user, "canceled",
          occurred_at: "2026-10-05T00:00:00Z"
        )
      )

      # Older stamp than the cancel, but the old row is canceled: a real resubscribe.
      send_payload(
        sub_event("subscription.created", "ntf_r2", "sub_r2", user, "active",
          occurred_at: "2026-10-04T00:00:00Z"
        )
      )

      assert %{paddle_subscription_id: "sub_r2", status: "active"} =
               Engram.Billing.get_subscription(user)
    end
  end

  defp sub_event(type, event_id, sub_id, user, status, opts \\ []) do
    Jason.encode!(%{
      "event_type" => type,
      "event_id" => event_id,
      "occurred_at" => Keyword.get(opts, :occurred_at, "2026-10-24T00:00:00Z"),
      "data" =>
        %{
          "id" => sub_id,
          "status" => status,
          "customer_id" => "ctm_#{sub_id}",
          "items" => [%{"price" => %{"id" => "pri_pro_monthly_test"}}],
          "current_billing_period" => %{"ends_at" => "2026-11-24T00:00:00Z"},
          "custom_data" => %{"user_id" => user.id}
        }
        |> then(
          &if(opts[:created_at], do: Map.put(&1, "created_at", opts[:created_at]), else: &1)
        )
    })
  end

  defp build_created_payload(user, affiliate_ref) do
    Jason.encode!(%{
      "event_type" => "subscription.created",
      "event_id" => "ntf_#{affiliate_ref}",
      "data" => %{
        "id" => "sub_replay_test",
        "status" => "trialing",
        "customer_id" => "ctm_replay_test",
        "items" => [%{"price" => %{"id" => "pri_starter_monthly_test"}}],
        "current_billing_period" => %{"ends_at" => "2026-05-20T00:00:00Z"},
        "custom_data" => %{"user_id" => user.id, "affiliate_ref" => affiliate_ref}
      }
    })
  end

  defp send_payload(payload) do
    timestamp = System.system_time(:second)
    signature = sign(timestamp, payload)

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("paddle-signature", "ts=#{timestamp};h1=#{signature}")
    |> post("/webhooks/paddle", payload)
  end

  defp sign(timestamp, payload) do
    secret = Application.fetch_env!(:engram, :paddle_notification_secret)
    signed_payload = "#{timestamp}:#{payload}"

    :crypto.mac(:hmac, :sha256, secret, signed_payload)
    |> Base.encode16(case: :lower)
  end
end
