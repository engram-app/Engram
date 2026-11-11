defmodule EngramWeb.Plugs.DeviceAuthRateLimitTest do
  @moduledoc """
  Device sign-in and token refresh are limited per CREDENTIAL, so everyone
  behind one network address gets their own bucket; the IP is only a ceiling.

  These run against the PRODUCTION limits (both test overrides cleared).
  """
  # async: false: limiter buckets and the override env are global.
  use EngramWeb.ConnCase, async: false

  alias EngramWeb.Plugs.DeviceAuthRateLimit

  @start "/api/auth/device"
  @poll "/api/auth/device/token"
  @refresh "/api/auth/token/refresh"
  @credential_limit 30
  @start_limit 300
  @ip_limit 3_000
  @ip {127, 0, 0, 1}

  setup do
    for key <- [:rate_limit_override, :oauth_ip_rate_limit_override] do
      previous = Application.get_env(:engram, key)
      Application.delete_env(:engram, key)
      on_exit(fn -> Application.put_env(:engram, key, previous) end)
    end

    EngramWeb.RateLimiter.reset_buckets!()
    :ok
  end

  defp call(path, params, ip \\ @ip) do
    build_conn(:post, path)
    |> Map.merge(%{remote_ip: ip, params: params})
    |> DeviceAuthRateLimit.call([])
  end

  defp hit(path, param, code, ip \\ @ip), do: call(path, %{param => code}, ip)

  defp limited?(conn), do: conn.halted and conn.status == 429

  for {path, param} <- [{@poll, "device_code"}, {@refresh, "refresh_token"}] do
    describe "#{path}" do
      test "through the router, one credential gets #{@credential_limit} and then 429" do
        code = Ecto.UUID.generate()

        for _ <- 1..@credential_limit do
          refute post(build_conn(), unquote(path), %{unquote(param) => code}).status == 429
        end

        conn = post(build_conn(), unquote(path), %{unquote(param) => code})
        assert json_response(conn, 429)["error"] == "rate_limited"
      end

      test "two credentials from one IP do not share a bucket" do
        abusive = Ecto.UUID.generate()

        for _ <- 1..@credential_limit,
            do: refute(limited?(hit(unquote(path), unquote(param), abusive)))

        assert limited?(hit(unquote(path), unquote(param), abusive))
        refute limited?(hit(unquote(path), unquote(param), Ecto.UUID.generate()))
      end

      test "a storm on one credential is limited across IPs" do
        code = Ecto.UUID.generate()

        for n <- 1..@credential_limit do
          refute limited?(hit(unquote(path), unquote(param), code, {198, 51, 100, n}))
        end

        assert limited?(hit(unquote(path), unquote(param), code, {203, 0, 113, 9}))
      end

      test "an extra parameter the route ignores does not buy a fresh bucket" do
        code = Ecto.UUID.generate()
        other = if unquote(param) == "device_code", do: "refresh_token", else: "device_code"

        for _ <- 1..@credential_limit do
          params = %{unquote(param) => code, other => Ecto.UUID.generate()}
          refute limited?(call(unquote(path), params))
        end

        assert limited?(
                 call(unquote(path), %{unquote(param) => code, other => Ecto.UUID.generate()})
               )
      end

      test "the IP ceiling holds across invented credentials" do
        for _ <- 1..@ip_limit do
          refute limited?(hit(unquote(path), unquote(param), Ecto.UUID.generate()))
        end

        assert limited?(hit(unquote(path), unquote(param), Ecto.UUID.generate()))
      end

      test "requests a credential bucket refuses do not drain the IP ceiling" do
        flooder = Ecto.UUID.generate()
        for _ <- 1..@ip_limit, do: hit(unquote(path), unquote(param), flooder)

        refute limited?(hit(unquote(path), unquote(param), Ecto.UUID.generate()))
      end

      test "a missing or non-string credential falls back to a per-IP bucket" do
        for n <- 1..@credential_limit do
          params = if rem(n, 2) == 0, do: %{}, else: %{unquote(param) => 123}
          refute limited?(call(unquote(path), params))
        end

        assert limited?(call(unquote(path), %{}))
        refute limited?(call(unquote(path), %{}, {198, 51, 100, 7}))
      end

      test "the raw credential never reaches a limiter key" do
        code = "raw-credential-" <> Ecto.UUID.generate()
        hit(unquote(path), unquote(param), code)

        refute inspect(:ets.tab2list(EngramWeb.RateLimiter.ETS)) =~ code
      end
    end
  end

  describe "#{@start}" do
    test "through the router, one IP gets #{@start_limit} and then 429" do
      for _ <- 1..@start_limit do
        refute post(build_conn(), @start, %{client_id: "test_client"}).status == 429
      end

      conn = post(build_conn(), @start, %{client_id: "test_client"})
      assert json_response(conn, 429)["error"] == "rate_limited"
    end

    test "a second IP has its own bucket" do
      for _ <- 1..@start_limit, do: refute(limited?(call(@start, %{})))

      assert limited?(call(@start, %{}))
      refute limited?(call(@start, %{}, {198, 51, 100, 7}))
    end
  end
end
