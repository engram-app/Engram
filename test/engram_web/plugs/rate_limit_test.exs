defmodule EngramWeb.Plugs.RateLimitTest do
  use EngramWeb.ConnCase, async: false

  # Restore the high rate-limit ceiling after all tests in this module finish.
  setup_all do
    on_exit(fn ->
      Application.put_env(:engram, :rate_limit_override, 10_000)
    end)

    :ok
  end

  @test_limit 3

  setup do
    Application.put_env(:engram, :rate_limit_override, @test_limit)

    EngramWeb.RateLimiter.reset_buckets!()
    :ok
  end

  describe "rate limiting on device flow start" do
    test "allows requests under the limit" do
      conn = build_conn()
      conn = post(conn, "/api/auth/device", %{client_id: "test_client"})
      assert conn.status == 200
    end

    test "spoofing x-forwarded-for does not bypass the rate limit" do
      for i <- 1..(@test_limit + 1) do
        build_conn()
        |> put_req_header("x-forwarded-for", "10.0.0.#{i}")
        |> post("/api/auth/device", %{client_id: "test_client"})
      end

      conn =
        build_conn()
        |> put_req_header("x-forwarded-for", "10.0.0.99")
        |> post("/api/auth/device", %{client_id: "test_client"})

      assert conn.status == 429
    end

    test "returns 429 after exceeding limit" do
      for _ <- 1..(@test_limit + 1) do
        build_conn() |> post("/api/auth/device", %{client_id: "test_client"})
      end

      conn = build_conn() |> post("/api/auth/device", %{client_id: "test_client"})
      assert conn.status == 429
      assert json_response(conn, 429)["error"] == "rate_limited"
    end
  end

  describe "rate limiting on device token poll" do
    test "returns 429 after exceeding limit on token poll" do
      for _ <- 1..(@test_limit + 1) do
        build_conn() |> post("/api/auth/device/token", %{device_code: "fake_code"})
      end

      conn = build_conn() |> post("/api/auth/device/token", %{device_code: "fake_code"})
      assert conn.status == 429
    end
  end

  # A 429 on the OAuth pipeline is a vendor that cannot connect. The metric tag
  # is what makes it attributable and what alerts (#1643).
  describe "purpose tagging" do
    setup do
      handler = "rate-limit-purpose-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:engram, :rate_limiter, :hit],
        fn _event, _measure, meta, _cfg -> send(test_pid, {:hit, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      :ok
    end

    test "a 429 on the oauth pipeline is attributable to oauth, not generic http" do
      for _ <- 1..(@test_limit + 1) do
        build_conn() |> post("/oauth/token", %{"grant_type" => "password"})
      end

      conn = build_conn() |> post("/oauth/token", %{"grant_type" => "password"})
      assert conn.status == 429

      assert_receive {:hit, %{purpose: :oauth, result: :deny}}
    end

    test "the device-flow limiter keeps its generic http purpose" do
      build_conn() |> post("/api/auth/device", %{client_id: "test_client"})

      assert_receive {:hit, %{purpose: :http, result: :allow}}
    end
  end

  # The limits as shipped, through the real router. Every other test here runs
  # under the low override, which would hide a wrong number in the pipeline.
  describe "shipped auth limits" do
    @strict_limit 10
    @body %{email: "nobody@example.test", password: "wrong-password", token: "fake_token"}

    # Each burst of 11 starts with its whole length left in the window
    # (`reset_buckets!/1`): Hammer's window is fixed and epoch-aligned, and a
    # burst across its edge lands the 11th request in a new window (CI
    # 2026-11-13: the login burst ran 06:39:58.4 to 06:40:01.3). Login and
    # register hash a password per request (~290 ms on CI, 3.2-3.5 s a burst
    # locally); the rest take well under the default margin.
    @slow_ms 6_000
    @slow ~w(/api/auth/login /api/auth/register)

    setup do
      Application.delete_env(:engram, :rate_limit_override)
      :ok
    end

    # None of these is gated by a high-entropy secret (or has no need of a
    # higher limit), so they must not ride along with the device routes.
    for path <- ~w(/api/auth/login /api/auth/register /api/auth/refresh /api/auth/logout
                   /api/auth/password/reset /api/telemetry/ping /api/auth/clear-cache) do
      test "#{path} stays at #{@strict_limit} per IP" do
        if unquote(path) in @slow,
          do: EngramWeb.RateLimiter.reset_buckets!(@slow_ms),
          else: EngramWeb.RateLimiter.reset_buckets!()

        for _ <- 1..@strict_limit do
          refute post(build_conn(), unquote(path), @body).status == 429
        end

        assert post(build_conn(), unquote(path), @body).status == 429
      end
    end

    for path <- ~w(/api/auth/bootstrap /api/auth/invite/some-token) do
      test "GET #{path} stays at #{@strict_limit} per IP" do
        EngramWeb.RateLimiter.reset_buckets!()
        for _ <- 1..@strict_limit, do: refute(get(build_conn(), unquote(path)).status == 429)

        assert get(build_conn(), unquote(path)).status == 429
      end
    end
  end

  describe "rate limit buckets are per-path" do
    test "exhausting device start limit does not affect token poll" do
      for _ <- 1..(@test_limit + 1) do
        build_conn() |> post("/api/auth/device", %{client_id: "test_client"})
      end

      # token poll has its own bucket — should not be 429
      conn = build_conn() |> post("/api/auth/device/token", %{device_code: "fake_code"})
      refute conn.status == 429
    end
  end
end
