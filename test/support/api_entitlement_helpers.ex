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

  # Writes the row, then evicts `Engram.Billing.OverrideCache` for this user.
  #
  # The eviction is NOT optional. That cache is node-global ETS with a 60s TTL
  # and it caches MISSES as well as hits; the pg NOTIFY trigger that normally
  # evicts it can never fire under the Ecto sandbox, because `pg_notify` only
  # delivers on COMMIT and the sandbox always rolls back. So if anything in a
  # setup resolves a limit for this user BEFORE the grant, the miss is cached
  # and the grant has no effect for 60s — presenting as an order-dependent
  # flake in a suite where the failure ("api_access_not_available") has
  # nothing to do with the assertion.
  #
  # `evict/1` is per-user; `clear_local/0` is a node-global wipe and is wrong
  # in an async suite.
  defp upsert_override!(user, key, value) do
    case Engram.Repo.get_by(Engram.Billing.UserLimitOverride, user_id: user.id, key: key) do
      nil ->
        Engram.Factory.insert(:user_limit_override, user: user, key: key, value: %{"v" => value})

      existing ->
        # Was `:noop`, which quietly broke the documented idempotency: a second
        # grant with a different value left the first one in place.
        existing
        |> Ecto.Changeset.change(value: %{"v" => value})
        |> Engram.Repo.update!()
    end

    Engram.Billing.OverrideCache.evict(user.id)
  end
end
