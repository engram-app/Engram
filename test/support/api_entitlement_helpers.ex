defmodule Engram.ApiEntitlementHelpers do
  @moduledoc """
  Lifts a test user's `api_rps_cap` via `user_limit_overrides`.

  Every tier has API access since #1974, capped at 30 requests/s per user.
  A test that fires a burst of API-key requests (or mints a key to exercise
  something else and should never trip the cap by accident) lifts it to
  1000. Shared by `ConnCase` and `ChannelCase` so the two cannot drift.

  JWT-authed sockets and requests are exempt from the cap, so tests that do
  not mint a key need none of this.
  """

  @doc """
  Sets a generous `api_rps_cap=1000`. Idempotent. Returns `user` for
  pipe-friendliness.
  """
  def lift_api_rps_cap!(%Engram.Accounts.User{} = user) do
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
