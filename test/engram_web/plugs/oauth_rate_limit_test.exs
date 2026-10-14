defmodule EngramWeb.Plugs.OAuthRateLimitTest do
  @moduledoc """
  The OAuth endpoint limiter is keyed by CLIENT on the token/revoke endpoints
  (#1974). It used to be 10/min per path per IP, and ChatGPT and Claude call
  `/oauth/token` from shared backend IPs, so all of their users drew from one
  bucket and one busy minute refused everyone's refresh.
  """
  # async: false — limiter buckets and the override env are global.
  use EngramWeb.ConnCase, async: false

  @limit 3

  setup do
    Application.put_env(:engram, :rate_limit_override, @limit)
    EngramWeb.RateLimiter.reset_buckets!()
    on_exit(fn -> Application.put_env(:engram, :rate_limit_override, 10_000) end)
    :ok
  end

  defp token(client_id, ip \\ {127, 0, 0, 1}, path \\ "/oauth/token") do
    build_conn()
    |> Map.put(:remote_ip, ip)
    |> post(path, %{
      "grant_type" => "refresh_token",
      "refresh_token" => "engram_oauth_rt_nope",
      "client_id" => client_id
    })
  end

  test "two client_ids from the same IP do not share a bucket" do
    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()

    for _ <- 1..@limit, do: refute(token(a).status == 429)
    assert token(a).status == 429

    refute token(b).status == 429
  end

  # Review #1: a CIMD client_id is a public URL shared by every ChatGPT user,
  # so a bucket keyed on it alone let ANY caller exhaust the whole vendor.
  test "an attacker exhausting a client_id from one IP does not 429 it from another IP" do
    shared = "https://chatgpt.com/oauth/client.json"
    attacker = {203, 0, 113, 9}
    vendor = {198, 51, 100, 7}

    for _ <- 1..@limit, do: token(shared, attacker)
    assert token(shared, attacker).status == 429

    refute token(shared, vendor).status == 429
  end

  test "/oauth/token/ (trailing slash) draws from the same bucket as /oauth/token" do
    a = Ecto.UUID.generate()
    for _ <- 1..@limit, do: token(a)
    assert token(a, {127, 0, 0, 1}, "/oauth/token/").status == 429
  end

  test "a client over its limit gets 429 with Retry-After and an RFC 6749 body" do
    a = Ecto.UUID.generate()
    for _ <- 1..@limit, do: token(a)

    conn = token(a)
    assert conn.status == 429
    assert [retry_after] = get_resp_header(conn, "retry-after")
    assert String.to_integer(retry_after) >= 1

    assert %{"error" => "temporarily_unavailable", "error_description" => _} =
             json_response(conn, 429)
  end

  test "the per-IP coarse bucket still bounds one IP across many client_ids" do
    Application.put_env(:engram, :oauth_ip_rate_limit_override, @limit)
    on_exit(fn -> Application.put_env(:engram, :oauth_ip_rate_limit_override, 10_000) end)

    for _ <- 1..@limit, do: token(Ecto.UUID.generate())
    assert token(Ecto.UUID.generate()).status == 429
  end

  test "authorize stays strictly per IP" do
    for _ <- 1..@limit,
        do: get(build_conn(), "/oauth/authorize", %{"client_id" => Ecto.UUID.generate()})

    assert get(build_conn(), "/oauth/authorize", %{"client_id" => Ecto.UUID.generate()}).status ==
             429
  end
end
