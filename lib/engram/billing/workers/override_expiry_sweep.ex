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

    :telemetry.execute(
      [:engram, :billing, :overrides, :expired],
      %{count: count},
      %{}
    )

    :ok
  end
end
