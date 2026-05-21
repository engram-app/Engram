defmodule EngramWeb.ClerkWebhookTest do
  use EngramWeb.ConnCase, async: false

  import Mox

  alias Engram.Accounts
  alias Engram.Repo

  setup :verify_on_exit!

  describe "POST /webhooks/clerk — signature verification" do
    test "returns 400 when svix-signature header missing", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/clerk", "{}")

      assert json_response(conn, 400)["error"] =~ "svix-signature"
    end

    test "returns 400 when svix-id header missing", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("svix-signature", "v1,deadbeef")
        |> put_req_header("svix-timestamp", "#{System.system_time(:second)}")
        |> post("/webhooks/clerk", "{}")

      assert json_response(conn, 400)["error"] =~ "svix-id"
    end

    test "returns 400 when signature is invalid", %{conn: conn} do
      conn =
        conn
        |> with_clerk_headers("evt_invalid", System.system_time(:second), "v1,not-a-real-sig")
        |> post("/webhooks/clerk", "{}")

      assert json_response(conn, 400)["error"] =~ "signature"
    end

    test "returns 400 for stale timestamp (>5min old)", %{conn: conn} do
      payload = ~s({"type":"user.created","data":{}})
      stale_ts = System.system_time(:second) - 360
      sig = sign_clerk("evt_stale", stale_ts, payload)

      conn =
        conn
        |> with_clerk_headers("evt_stale", stale_ts, sig)
        |> post("/webhooks/clerk", payload)

      assert json_response(conn, 400)["error"] =~ "old"
    end

    test "returns 400 for future-dated timestamp (clock-skew replay defense)", %{conn: conn} do
      payload = ~s({"type":"user.created","data":{}})
      future_ts = System.system_time(:second) + 360
      sig = sign_clerk("evt_future", future_ts, payload)

      conn =
        conn
        |> with_clerk_headers("evt_future", future_ts, sig)
        |> post("/webhooks/clerk", payload)

      assert json_response(conn, 400)["error"] =~ "old"
    end

    test "accepts multi-signature header (rotation) when one entry matches", %{conn: conn} do
      payload = ~s({"type":"user.created","data":{"id":"x","email_addresses":[]}})
      ts = System.system_time(:second)
      good = sign_clerk("evt_multi", ts, payload)
      multi_sig = "v1,bogusoldsigvalue #{good}"

      conn =
        conn
        |> with_clerk_headers("evt_multi", ts, multi_sig)
        |> post("/webhooks/clerk", payload)

      assert json_response(conn, 200)["status"] == "ok"
    end
  end

  describe "POST /webhooks/clerk — user.created" do
    test "creates local user row when email is new", %{conn: conn} do
      payload = clerk_user_created_payload("user_new1", "new.user@gmail.com")
      conn = post_clerk(conn, "evt_new1", payload)

      assert json_response(conn, 200)["status"] == "ok"
      assert {:ok, user} = Accounts.find_by_external_id("user_new1")
      assert user.email == "new.user@gmail.com"
      assert user.normalized_email == "newuser@gmail.com"
    end

    test "rejects and calls Clerk API delete when normalized email duplicates existing user",
         %{conn: conn} do
      # Existing user normalized form is "mefoo@gmail.com". Incoming alias
      # "Me.Foo+spam@gmail.com" collapses to the same form.
      _existing = insert(:user, email: "me.foo@gmail.com", normalized_email: "mefoo@gmail.com")

      expect(Engram.Auth.Clerk.ApiMock, :delete_user, fn "user_dup1" -> :ok end)

      payload = clerk_user_created_payload("user_dup1", "Me.Foo+spam@gmail.com")
      conn = post_clerk(conn, "evt_dup1", payload)

      assert json_response(conn, 200)["status"] == "ok"
      assert {:error, :user_not_found} = Accounts.find_by_external_id("user_dup1")
    end

    test "ignores duplicate event when local user already exists for same external_id",
         %{conn: conn} do
      existing =
        insert(:user, email: "existing@gmail.com", normalized_email: "existing@gmail.com")

      existing
      |> Ecto.Changeset.change(%{external_id: "user_repeat"})
      |> Repo.update!(skip_tenant_check: true)

      payload = clerk_user_created_payload("user_repeat", "existing@gmail.com")
      conn = post_clerk(conn, "evt_repeat", payload)

      assert json_response(conn, 200)["status"] == "ok"
    end
  end

  describe "POST /webhooks/clerk — user.updated phone verification" do
    setup do
      user = insert(:user, email: "phone@gmail.com", normalized_email: "phone@gmail.com")

      user
      |> Ecto.Changeset.change(%{external_id: "user_phone"})
      |> Repo.update!(skip_tenant_check: true)

      %{user: user}
    end

    test "sets phone_verified_at when verified flag flips true", %{conn: conn, user: user} do
      payload = clerk_user_updated_payload("user_phone", phone_verified: true)
      conn = post_clerk(conn, "evt_phone1", payload)

      assert json_response(conn, 200)["status"] == "ok"
      assert %{phone_verified_at: %DateTime{}} = Repo.reload!(user)
    end

    test "leaves phone_verified_at nil when no verified phone present", %{conn: conn, user: user} do
      payload = clerk_user_updated_payload("user_phone", phone_verified: false)
      conn = post_clerk(conn, "evt_phone2", payload)

      assert json_response(conn, 200)["status"] == "ok"
      assert %{phone_verified_at: nil} = Repo.reload!(user)
    end
  end

  describe "POST /webhooks/clerk — other events" do
    test "returns 200 and no-ops for unknown event type", %{conn: conn} do
      payload = Jason.encode!(%{"type" => "session.created", "data" => %{}})
      conn = post_clerk(conn, "evt_unknown", payload)

      assert json_response(conn, 200)["status"] == "ok"
    end
  end

  # ── helpers ─────────────────────────────────────────────────

  defp clerk_user_created_payload(clerk_id, email) do
    Jason.encode!(%{
      "type" => "user.created",
      "data" => %{
        "id" => clerk_id,
        "email_addresses" => [
          %{
            "id" => "email_1",
            "email_address" => email,
            "verification" => %{"status" => "verified"}
          }
        ],
        "primary_email_address_id" => "email_1",
        "phone_numbers" => []
      }
    })
  end

  defp clerk_user_updated_payload(clerk_id, phone_verified: verified) do
    phones =
      if verified do
        [
          %{
            "id" => "phone_1",
            "phone_number" => "+15555550100",
            "verification" => %{"status" => "verified"}
          }
        ]
      else
        []
      end

    Jason.encode!(%{
      "type" => "user.updated",
      "data" => %{
        "id" => clerk_id,
        "email_addresses" => [
          %{
            "id" => "email_1",
            "email_address" => "phone@gmail.com",
            "verification" => %{"status" => "verified"}
          }
        ],
        "primary_email_address_id" => "email_1",
        "phone_numbers" => phones
      }
    })
  end

  defp post_clerk(conn, event_id, payload) do
    ts = System.system_time(:second)
    sig = sign_clerk(event_id, ts, payload)

    conn
    |> with_clerk_headers(event_id, ts, sig)
    |> post("/webhooks/clerk", payload)
  end

  defp with_clerk_headers(conn, id, ts, sig) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("svix-id", id)
    |> put_req_header("svix-timestamp", "#{ts}")
    |> put_req_header("svix-signature", sig)
  end

  defp sign_clerk(id, ts, payload) do
    secret =
      Application.fetch_env!(:engram, :clerk_webhook_secret)
      |> String.replace_prefix("whsec_", "")
      |> Base.decode64!()

    body = "#{id}.#{ts}.#{payload}"
    mac = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode64()
    "v1,#{mac}"
  end
end
