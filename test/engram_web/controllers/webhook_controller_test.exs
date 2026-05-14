defmodule EngramWeb.WebhookControllerTest do
  use EngramWeb.ConnCase, async: true

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
            "items" => [%{"price" => %{"id" => "pri_starter_test"}}],
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
  end

  defp sign(timestamp, payload) do
    secret = Application.fetch_env!(:engram, :paddle_notification_secret)
    signed_payload = "#{timestamp}:#{payload}"

    :crypto.mac(:hmac, :sha256, secret, signed_payload)
    |> Base.encode16(case: :lower)
  end
end
