defmodule Engram.Auth.Clerk.HttpApiTest do
  # async: false -- mutates global app env (:clerk_api_base_url, :clerk_secret_key).
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Engram.Auth.Clerk.HttpApi

  setup do
    bypass = Bypass.open()
    prev_url = Application.get_env(:engram, :clerk_api_base_url)
    prev_key = Application.get_env(:engram, :clerk_secret_key)
    Application.put_env(:engram, :clerk_api_base_url, "http://localhost:#{bypass.port}/v1")
    Application.put_env(:engram, :clerk_secret_key, "sk_test_x")

    on_exit(fn ->
      restore(:clerk_api_base_url, prev_url)
      restore(:clerk_secret_key, prev_key)
    end)

    %{bypass: bypass}
  end

  defp restore(key, nil), do: Application.delete_env(:engram, key)
  defp restore(key, value), do: Application.put_env(:engram, key, value)

  defp respond(bypass, status) do
    Bypass.expect_once(bypass, "DELETE", "/v1/users/user_abc", fn conn ->
      Plug.Conn.resp(conn, status, ~s({"errors":[]}))
    end)
  end

  test "2xx is :ok", %{bypass: bypass} do
    respond(bypass, 200)
    assert :ok = HttpApi.delete_user("user_abc")
  end

  test "404 means the Clerk user is already gone: :ok, and no error log", %{bypass: bypass} do
    respond(bypass, 404)

    log = capture_log([level: :warning], fn -> assert :ok = HttpApi.delete_user("user_abc") end)

    refute log =~ "[error]"
    refute log =~ "delete_user failed"
  end

  test "a real failure (5xx) still errors and logs at error", %{bypass: bypass} do
    respond(bypass, 500)

    log =
      capture_log(fn ->
        assert {:error, {:http_error, 500}} = HttpApi.delete_user("user_abc")
      end)

    assert log =~ "Clerk delete_user failed"
  end

  test "an auth failure (401) still errors", %{bypass: bypass} do
    respond(bypass, 401)
    capture_log(fn -> assert {:error, {:http_error, 401}} = HttpApi.delete_user("user_abc") end)
  end

  describe "latest_activity/1" do
    defp sessions(bypass, status, body) do
      Bypass.expect_once(bypass, "GET", "/v1/sessions", fn conn ->
        assert conn.query_string =~ "user_id=user_1"
        Plug.Conn.resp(conn, status, Jason.encode!(body))
      end)
    end

    test "reads country and device_type, never ip or city", %{bypass: bypass} do
      sessions(bypass, 200, [
        %{
          "latest_activity" => %{
            "country" => "br",
            "city" => "Sao Paulo",
            "ip_address" => "203.0.113.9",
            "device_type" => "iPhone",
            "is_mobile" => true
          }
        }
      ])

      assert {:ok, activity} = HttpApi.latest_activity("user_1")
      assert activity == %{country: "BR", device_type: "iphone"}
    end

    test "falls back to is_mobile and drops a non-code country", %{bypass: bypass} do
      sessions(bypass, 200, [
        %{"latest_activity" => %{"country" => "Brazil", "is_mobile" => false}}
      ])

      assert {:ok, %{country: nil, device_type: "desktop"}} = HttpApi.latest_activity("user_1")
    end

    test "no sessions is {:ok, nil}", %{bypass: bypass} do
      sessions(bypass, 200, [])
      assert {:ok, nil} = HttpApi.latest_activity("user_1")
    end

    test "an HTTP error is an error tuple", %{bypass: bypass} do
      sessions(bypass, 429, %{})
      assert {:error, {:http_error, 429}} = HttpApi.latest_activity("user_1")
    end
  end
end
