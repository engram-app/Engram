defmodule EngramWeb.Plugs.DeviceFingerprintTest do
  use EngramWeb.ConnCase, async: false

  alias EngramWeb.Plugs.DeviceFingerprint

  describe "call/2" do
    setup do
      ref =
        :telemetry_test.attach_event_handlers(self(), [[:engram, :abuse, :device_fingerprint]])

      on_exit(fn -> :telemetry.detach(ref) end)
      :ok
    end

    test "emits telemetry with UA hash and user_id", %{conn: conn} do
      user = insert(:user)

      conn
      |> Plug.Conn.put_req_header("user-agent", "Engram-Obsidian/0.5.0")
      |> Plug.Conn.assign(:current_user, user)
      |> DeviceFingerprint.call([])

      assert_received {[:engram, :abuse, :device_fingerprint], _ref, %{count: 1},
                       %{user_id: uid, fingerprint: fp}}

      assert uid == user.id
      assert is_binary(fp) and byte_size(fp) == 12
    end

    test "same UA yields same fingerprint across requests", %{conn: conn} do
      user = insert(:user)
      ua = "Engram-Obsidian/0.5.0"

      for _ <- 1..2 do
        conn
        |> Plug.Conn.put_req_header("user-agent", ua)
        |> Plug.Conn.assign(:current_user, user)
        |> DeviceFingerprint.call([])
      end

      assert_received {_, _, _, %{fingerprint: fp1}}
      assert_received {_, _, _, %{fingerprint: fp2}}
      assert fp1 == fp2
    end

    test "different UAs yield different fingerprints", %{conn: conn} do
      user = insert(:user)

      conn
      |> Plug.Conn.put_req_header("user-agent", "Engram-Obsidian/0.5.0")
      |> Plug.Conn.assign(:current_user, user)
      |> DeviceFingerprint.call([])

      conn
      |> Plug.Conn.put_req_header("user-agent", "Engram-CLI/1.0")
      |> Plug.Conn.assign(:current_user, user)
      |> DeviceFingerprint.call([])

      assert_received {_, _, _, %{fingerprint: fp1}}
      assert_received {_, _, _, %{fingerprint: fp2}}
      refute fp1 == fp2
    end

    test "no-op when current_user not assigned", %{conn: conn} do
      assert ^conn = DeviceFingerprint.call(conn, [])
      refute_received {[:engram, :abuse, :device_fingerprint], _, _, _}
    end
  end
end
