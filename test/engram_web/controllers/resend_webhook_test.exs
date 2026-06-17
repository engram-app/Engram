defmodule EngramWeb.ResendWebhookTest do
  use EngramWeb.ConnCase, async: true

  alias Engram.Email.Suppression

  describe "POST /webhooks/resend — signature verification" do
    test "returns 400 when the signature is invalid", %{conn: conn} do
      payload = ~s({"type":"email.bounced","data":{"to":["x@example.com"]}})

      conn =
        conn
        |> with_resend_headers("evt_1", System.system_time(:second), "v1,not-a-real-sig")
        |> post("/webhooks/resend", payload)

      assert json_response(conn, 400)["error"] =~ "signature"
      refute Suppression.suppressed?("x@example.com")
    end

    test "returns 400 for a stale timestamp", %{conn: conn} do
      payload = ~s({"type":"email.bounced","data":{"to":["stale@example.com"]}})
      stale_ts = System.system_time(:second) - 360
      sig = sign_resend("evt_stale", stale_ts, payload)

      conn =
        conn
        |> with_resend_headers("evt_stale", stale_ts, sig)
        |> post("/webhooks/resend", payload)

      assert json_response(conn, 400)["error"] =~ "old"
      refute Suppression.suppressed?("stale@example.com")
    end
  end

  describe "POST /webhooks/resend — event handling" do
    test "suppresses recipients on a bounce", %{conn: conn} do
      conn = post_resend(conn, "evt_b", "email.bounced", ["bounce@example.com"])

      assert json_response(conn, 200)["status"] == "ok"
      assert Suppression.suppressed?("bounce@example.com")
    end

    test "suppresses recipients on a complaint", %{conn: conn} do
      conn = post_resend(conn, "evt_c", "email.complained", ["spam@example.com"])

      assert json_response(conn, 200)["status"] == "ok"
      assert Suppression.suppressed?("spam@example.com")
    end

    test "ignores non-suppression events (e.g. delivered)", %{conn: conn} do
      conn = post_resend(conn, "evt_d", "email.delivered", ["fine@example.com"])

      assert json_response(conn, 200)["status"] == "ok"
      refute Suppression.suppressed?("fine@example.com")
    end

    test "suppresses a permanent bounce", %{conn: conn} do
      conn =
        post_resend(conn, "evt_perm", "email.bounced", ["perm@example.com"], %{
          "bounce" => %{"type" => "Permanent"}
        })

      assert json_response(conn, 200)["status"] == "ok"
      assert Suppression.suppressed?("perm@example.com")
    end

    test "ignores a transient bounce (does not suppress)", %{conn: conn} do
      conn =
        post_resend(conn, "evt_trans", "email.bounced", ["transient@example.com"], %{
          "bounce" => %{"type" => "Transient"}
        })

      assert json_response(conn, 200)["status"] == "ok"
      refute Suppression.suppressed?("transient@example.com")
    end

    test "suppresses every recipient in a multi-address event", %{conn: conn} do
      conn =
        post_resend(conn, "evt_multi", "email.complained", ["a@example.com", "b@example.com"])

      assert json_response(conn, 200)["status"] == "ok"
      assert Suppression.suppressed?("a@example.com")
      assert Suppression.suppressed?("b@example.com")
    end

    test "acknowledges an event with no recipients without crashing", %{conn: conn} do
      payload = Jason.encode!(%{type: "email.bounced", data: %{}})
      ts = System.system_time(:second)
      sig = sign_resend("evt_empty", ts, payload)

      conn =
        conn
        |> with_resend_headers("evt_empty", ts, sig)
        |> post("/webhooks/resend", payload)

      assert json_response(conn, 200)["status"] == "ok"
    end
  end

  defp post_resend(conn, id, type, recipients, extra_data \\ %{}) do
    payload = Jason.encode!(%{type: type, data: Map.merge(%{to: recipients}, extra_data)})
    ts = System.system_time(:second)
    sig = sign_resend(id, ts, payload)

    conn
    |> with_resend_headers(id, ts, sig)
    |> post("/webhooks/resend", payload)
  end

  defp with_resend_headers(conn, id, ts, sig) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("svix-id", id)
    |> put_req_header("svix-timestamp", "#{ts}")
    |> put_req_header("svix-signature", sig)
  end

  defp sign_resend(id, ts, payload) do
    secret =
      Application.fetch_env!(:engram, :resend_webhook_secret)
      |> String.replace_prefix("whsec_", "")
      |> Base.decode64!()

    mac = :crypto.mac(:hmac, :sha256, secret, "#{id}.#{ts}.#{payload}") |> Base.encode64()
    "v1,#{mac}"
  end
end
