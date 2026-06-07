defmodule EngramWeb.WebhookControllerTest do
  use EngramWeb.ConnCase, async: true

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

    test "subscription.canceled before subscription.created returns 200 without crashing", %{
      conn: conn
    } do
      user = insert(:user)

      payload =
        Jason.encode!(%{
          "event_type" => "subscription.canceled",
          "event_id" => "ntf_orphan_cancel",
          "data" => %{
            "id" => "sub_never_created",
            "status" => "canceled",
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
      refute Engram.Billing.get_subscription(user)
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
