defmodule EngramWeb.Plugs.NotesRateLimitTest do
  @moduledoc """
  Tests for the application-layer rate limiter that defends `/api/notes/*`
  against 401-loop attacks. Cloudflare cannot count response-conditional
  (auth-rejected) requests on the Free tier, so the defense lives in the
  app layer. See engram-app/Engram#357 / engram-infra#361.

  The plug MUST run before auth so that 401-failed requests still consume
  bucket capacity — that is the whole point.
  """
  use EngramWeb.ConnCase, async: false

  import Plug.Conn

  alias EngramWeb.Plugs.NotesRateLimit

  @test_limit 5
  @period_ms 60_000

  setup_all do
    on_exit(fn ->
      Application.put_env(:engram, :notes_rate_limit_override, nil)
    end)

    :ok
  end

  setup do
    Application.put_env(:engram, :notes_rate_limit_override, @test_limit)
    EngramWeb.RateLimiter.reset_buckets!()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Direct plug-level tests — fast, isolated from the rest of the pipeline.
  # ---------------------------------------------------------------------------

  defp run_plug(conn) do
    opts = NotesRateLimit.init(limit: @test_limit, period: @period_ms)
    NotesRateLimit.call(conn, opts)
  end

  defp notes_conn(opts \\ []) do
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    path = Keyword.get(opts, :path, "/api/notes/foo.md")
    auth = Keyword.get(opts, :auth)

    conn =
      :get
      |> Phoenix.ConnTest.build_conn(path, "")
      |> Map.put(:remote_ip, ip)

    case auth do
      nil -> conn
      header -> put_req_header(conn, "authorization", header)
    end
  end

  test "allows requests under the limit" do
    Enum.each(1..@test_limit, fn _ ->
      conn = run_plug(notes_conn())
      refute conn.halted
      refute conn.status == 429
    end)
  end

  test "returns 429 with Retry-After header above the limit" do
    Enum.each(1..@test_limit, fn _ -> run_plug(notes_conn()) end)

    conn = run_plug(notes_conn())
    assert conn.halted
    assert conn.status == 429
    assert ["rate_limited"] = get_resp_header(conn, "x-engram-error")
    assert [retry_after] = get_resp_header(conn, "retry-after")
    {retry_after_int, ""} = Integer.parse(retry_after)
    assert retry_after_int >= 1
    assert retry_after_int <= div(@period_ms, 1000)
    assert [limit_hdr] = get_resp_header(conn, "x-ratelimit-limit")
    assert limit_hdr == Integer.to_string(@test_limit)
    assert ["0"] = get_resp_header(conn, "x-ratelimit-remaining")
    assert {:ok, %{"error" => "rate_limited"}} = Jason.decode(conn.resp_body)
  end

  test "bypasses paths outside /api/notes" do
    Enum.each(1..(@test_limit * 3), fn _ ->
      conn = run_plug(notes_conn(path: "/api/health"))
      refute conn.halted
    end)
  end

  test "different IPs do not share buckets when unauthenticated" do
    Enum.each(1..@test_limit, fn _ ->
      run_plug(notes_conn(ip: {10, 0, 0, 1}))
    end)

    # Second IP starts fresh — should not be 429
    conn = run_plug(notes_conn(ip: {10, 0, 0, 2}))
    refute conn.halted
  end

  test "different JWT subs from the same IP do not share buckets" do
    jwt_a = make_unsigned_jwt(%{"sub" => "user_a"})
    jwt_b = make_unsigned_jwt(%{"sub" => "user_b"})

    Enum.each(1..@test_limit, fn _ ->
      run_plug(notes_conn(auth: "Bearer #{jwt_a}"))
    end)

    # Even from the same IP, user_b has its own bucket.
    conn = run_plug(notes_conn(auth: "Bearer #{jwt_b}"))
    refute conn.halted
  end

  test "auth-failed (unauthenticated) requests still count toward the bucket" do
    # The whole point: 401-loop attacks should be throttled at the IP level,
    # not waved through because the JWT was bad. Mix of malformed-JWT and
    # no-JWT requests from the same IP must consume the same bucket.
    for _ <- 1..3, do: run_plug(notes_conn(auth: "Bearer garbage"))
    for _ <- 1..2, do: run_plug(notes_conn())

    # 5 requests in -> next one is denied.
    conn = run_plug(notes_conn())
    assert conn.halted
    assert conn.status == 429
  end

  test "X-RateLimit-Remaining is exposed on allowed responses" do
    conn = run_plug(notes_conn())
    refute conn.halted
    assert [limit_hdr] = get_resp_header(conn, "x-ratelimit-limit")
    assert limit_hdr == Integer.to_string(@test_limit)
    assert [remaining_hdr] = get_resp_header(conn, "x-ratelimit-remaining")
    {remaining, ""} = Integer.parse(remaining_hdr)
    assert remaining >= 0
    assert remaining < @test_limit
  end

  # ---------------------------------------------------------------------------
  # End-to-end router test — confirms the plug runs before Auth on the
  # vault-scoped pipeline, so 401-rejected requests still consume the bucket.
  # This is the 401-loop defense in its real position.
  # ---------------------------------------------------------------------------

  describe "router pipeline — 401-loop defense" do
    test "bad-JWT requests against /api/notes/* still consume bucket capacity" do
      # Hit the limit with garbage Bearer tokens — every one gets 401, but
      # they ALL count toward the bucket.
      for _ <- 1..@test_limit do
        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer garbage")
          |> get("/api/notes/foo.md")

        assert conn.status == 401
      end

      # Next request — even with the same garbage token — should be 429,
      # not 401. The rate limiter ran first and short-circuited Auth.
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer garbage")
        |> get("/api/notes/foo.md")

      assert conn.status == 429
      assert [_retry] = get_resp_header(conn, "retry-after")
    end
  end

  test "spoofed x-forwarded-for does not bypass the IP bucket" do
    Enum.each(1..@test_limit, fn _ ->
      conn =
        notes_conn()
        |> put_req_header("x-forwarded-for", "10.0.0.99")

      run_plug(conn)
    end)

    conn =
      notes_conn()
      |> put_req_header("x-forwarded-for", "10.0.0.42")
      |> run_plug()

    assert conn.halted
    assert conn.status == 429
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Build a JWT-shaped string (header.payload.signature) where the payload
  # carries the given claims. We do NOT sign it — the plug uses sub purely as
  # a bucket key and never grants authority based on it.
  defp make_unsigned_jwt(claims) do
    header = Base.url_encode64(Jason.encode!(%{"alg" => "none", "typ" => "JWT"}), padding: false)
    payload = Base.url_encode64(Jason.encode!(claims), padding: false)
    "#{header}.#{payload}.signature"
  end
end
