defmodule EngramWeb.Plugs.OAuthRateLimitTest do
  @moduledoc """
  The OAuth endpoint limiter is keyed by CLIENT on the token/revoke endpoints
  (#1974). It used to be 10/min per path per IP, and ChatGPT and Claude call
  `/oauth/token` from shared backend IPs, so all of their users drew from one
  bucket and one busy minute refused everyone's refresh.

  These run against the PRODUCTION limits (both test overrides cleared), so
  the separation between the per-client bucket and the coarse per-IP bucket
  is the shipped one. The plug is called directly: filling a 1,200 bucket
  through the controller would only add time.
  """
  # async: false — limiter buckets and the override env are global.
  use EngramWeb.ConnCase, async: false

  alias EngramWeb.Plugs.OAuthRateLimit

  @client_limit 300
  @ip_limit 3_000

  setup do
    for key <- [:rate_limit_override, :oauth_ip_rate_limit_override] do
      previous = Application.get_env(:engram, key)
      Application.delete_env(:engram, key)
      on_exit(fn -> Application.put_env(:engram, key, previous) end)
    end

    EngramWeb.RateLimiter.reset_buckets!()
    :ok
  end

  defp token(client_id, ip \\ {127, 0, 0, 1}, path \\ "/oauth/token") do
    build_conn(:post, path)
    |> Map.merge(%{remote_ip: ip, params: %{"client_id" => client_id}})
    |> OAuthRateLimit.call([])
  end

  defp limited?(conn), do: conn.halted and conn.status == 429

  defp exhaust(client_id, ip \\ {127, 0, 0, 1}) do
    for _ <- 1..@client_limit, do: refute(limited?(token(client_id, ip)))
  end

  test "a client trips its own bucket long before the IP bucket" do
    a = Ecto.UUID.generate()
    exhaust(a)
    assert limited?(token(a))

    refute limited?(token(Ecto.UUID.generate()))
  end

  # Review #1: a CIMD client_id is a public URL shared by every ChatGPT user,
  # so a bucket keyed on it alone let ANY caller exhaust the whole vendor.
  test "an attacker exhausting a client_id from one IP does not 429 it from another IP" do
    shared = "https://chatgpt.com/oauth/client.json"
    attacker = {203, 0, 113, 9}

    exhaust(shared, attacker)
    assert limited?(token(shared, attacker))

    refute limited?(token(shared, {198, 51, 100, 7}))
  end

  test "/oauth/token/ (trailing slash) draws from the same bucket as /oauth/token" do
    a = Ecto.UUID.generate()
    exhaust(a)
    assert limited?(token(a, {127, 0, 0, 1}, "/oauth/token/"))
  end

  test "a client over its limit gets 429 with Retry-After and an RFC 6749 body" do
    a = Ecto.UUID.generate()
    exhaust(a)

    conn = token(a)
    assert conn.status == 429
    assert [retry_after] = get_resp_header(conn, "retry-after")
    assert String.to_integer(retry_after) >= 1

    assert %{"error" => "temporarily_unavailable", "error_description" => _} =
             Jason.decode!(conn.resp_body)
  end

  # Third review #8: requests the client bucket refuses must not also drain
  # the shared IP bucket, or one flooding client 429s every other client on
  # that IP (a vendor egress IP carries thousands).
  test "a client flooding past its limit does not drain the IP bucket for others" do
    flooder = Ecto.UUID.generate()
    exhaust(flooder)
    for _ <- 1..(@ip_limit - @client_limit), do: assert(limited?(token(flooder)))

    other = Ecto.UUID.generate()
    for _ <- 1..@client_limit, do: refute(limited?(token(other)))
  end

  test "the per-IP coarse bucket still bounds one IP across many client_ids" do
    for _ <- 1..@ip_limit, do: refute(limited?(token(Ecto.UUID.generate())))
    assert limited?(token(Ecto.UUID.generate()))
  end

  test "authorize stays strictly per IP" do
    for _ <- 1..10,
        do: get(build_conn(), "/oauth/authorize", %{"client_id" => Ecto.UUID.generate()})

    assert get(build_conn(), "/oauth/authorize", %{"client_id" => Ecto.UUID.generate()}).status ==
             429
  end
end
