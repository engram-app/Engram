defmodule Engram.Billing.Workers.OverrideExpirySweep do
  @moduledoc """
  Daily Oban cron worker that deletes expired `user_limit_overrides` rows.
  Emits `[:engram, :billing, :overrides, :expired]` telemetry with the
  number of rows deleted.
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 60, fields: [:worker]]

  import Ecto.Query

  alias Engram.Billing.UserLimitOverride
  alias Engram.Repo

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()

    {count, _} =
      Repo.delete_all(
        from(o in UserLimitOverride, where: o.expires_at <= ^now),
        skip_tenant_check: true
      )

    # Cached lookups (hits and misses) may now be wrong — flush so
    # expirations take effect without waiting out the cache TTL. Both the raw
    # override lookup cache and the resolved-entitlement cache derive from
    # these rows.
    if count > 0 do
      Engram.Billing.OverrideCache.evict_all()
      Engram.Billing.EntitlementCache.evict_all()
    end

    :telemetry.execute(
      [:engram, :billing, :overrides, :expired],
      %{count: count},
      %{}
    )

    :ok
  end
end
