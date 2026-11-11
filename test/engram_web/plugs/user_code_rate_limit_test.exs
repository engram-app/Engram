defmodule EngramWeb.Plugs.UserCodeRateLimitTest do
  @moduledoc """
  A signed-in user can test a short device user code two ways: approving it,
  and asking `GET /api/vaults?user_code=` whether it is valid. Both spend one
  per-user budget, so neither is a free guessing oracle (RFC 8628 section 5.1).
  """
  # async: false: limiter buckets and the override env are global.
  use EngramWeb.ConnCase, async: false

  @limit 20

  setup %{conn: conn} do
    previous = Application.get_env(:engram, :rate_limit_override)
    Application.delete_env(:engram, :rate_limit_override)
    on_exit(fn -> Application.put_env(:engram, :rate_limit_override, previous) end)
    EngramWeb.RateLimiter.reset_buckets!()

    {:ok, conn: signed_in(conn), other: signed_in(conn)}
  end

  defp signed_in(conn) do
    user = insert(:user) |> ensure_external_id()
    {:ok, token} = Engram.Auth.Providers.Local.issue_access_token(user.external_id, user.email)
    lift_api_rps_cap!(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp approve(conn), do: post(conn, "/api/auth/device/authorize", approve_params())
  defp probe(conn), do: get(conn, "/api/vaults", %{user_code: "ZZZZ-ZZZZ"})

  defp approve_params, do: %{user_code: "ZZZZ-ZZZZ", vault_id: Ecto.UUID.generate()}

  test "approval attempts are limited per user", %{conn: conn} do
    for _ <- 1..@limit, do: refute(approve(conn).status == 429)

    assert json_response(approve(conn), 429)["error"] == "rate_limited"
  end

  test "validity probes are limited per user", %{conn: conn} do
    for _ <- 1..@limit, do: refute(probe(conn).status == 429)

    assert probe(conn).status == 429
  end

  test "probing and approving spend one budget", %{conn: conn} do
    for _ <- 1..@limit, do: refute(probe(conn).status == 429)

    assert approve(conn).status == 429
  end

  test "one user's guessing does not limit another user", %{conn: conn, other: other} do
    for _ <- 1..(@limit + 1), do: probe(conn)

    refute probe(other).status == 429
  end

  test "listing vaults without a user code spends nothing", %{conn: conn} do
    for _ <- 1..(@limit + 1), do: assert(get(conn, "/api/vaults").status == 200)

    refute probe(conn).status == 429
  end
end
