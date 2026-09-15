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

  # A 429 on the OAuth pipeline is a vendor that cannot connect, and it is the
  # one refusal on that path deliberately left unlogged: /oauth/* is
  # unauthenticated, so one line per over-limit attempt is unbounded log volume
  # behind a bounded refusal — the same trade `Engram.OAuth.Cimd` already makes
  # for `:rate_limited`. The metric tag is what makes it attributable instead
  # (#1643).
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
