defmodule Engram.ApiEntitlementHelpers do
  @moduledoc """
  Grants paid-tier API entitlements via `user_limit_overrides`.

  Pricing v2 §G gives Free `api_write_enabled: false` and `api_rps_cap: 0`,
  and `RequireApiRpsBudget` has no GET exemption — so a Free API key cannot
  make a single REST call, and (since #1433) cannot open a `sync:`/`crdt:`
  socket either.

  That means **any test that mints an API key to exercise something else** —
  vault restriction, join tracing, channel logging — has to represent a paid
  user, or it fails on entitlement before reaching what it is actually
  testing. Shared by `ConnCase` and `ChannelCase` so the two cannot drift.

  JWT-authed sockets and requests are exempt from both gates, so tests that
  do not mint a key need none of this.
  """

  @doc """
  Grants `api_write_enabled=true` and a generous `api_rps_cap=1000`.
  Idempotent. Returns `user` for pipe-friendliness.
  """
  def grant_api_write!(%Engram.Accounts.User{} = user) do
    upsert_override!(user, "api_write_enabled", true)
    upsert_override!(user, "api_rps_cap", 1_000)
    user
  end

  @doc """
  Grants read-level API access only (`api_rps_cap`), leaving
  `api_write_enabled` at the tier default. Use when the test needs an API key
  to CONNECT but is asserting that writes are refused.
  """
  def grant_api_read!(%Engram.Accounts.User{} = user) do
    upsert_override!(user, "api_rps_cap", 1_000)
    user
  end

  defp upsert_override!(user, key, value) do
    case Engram.Repo.get_by(Engram.Billing.UserLimitOverride, user_id: user.id, key: key) do
      nil ->
        Engram.Factory.insert(:user_limit_override, user: user, key: key, value: %{"v" => value})

      _existing ->
        :noop
    end
  end
end
