defmodule Engram.Workers.InactivityCleanup do
  @moduledoc """
  Daily Oban cron that runs the §C inactivity ladder:

  - **60 days inactive** → warning #1 email + stamp `inactivity_warning_60_at`.
  - **80 days inactive** → final-notice email + stamp `inactivity_warning_80_at`.
  - **90 days inactive** → soft-delete: drop Qdrant points, S3 attachments,
    set `users.deleted_at`. Clerk identity untouched.
  - **30 days soft-deleted** → hard-delete: remove user row (cascades to
    notes/vaults/attachments via FK), wipe S3 bucket prefix.

  Paid-tier users (subscription.status in active/past_due/trialing) are
  exempt — they paid for the storage.

  All sweeps are idempotent: re-running the cron mid-day re-finds nothing
  because the warning timestamps and `deleted_at` prevent re-firing.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query

  alias Engram.Accounts.Lifecycle
  alias Engram.Accounts.User
  alias Engram.Billing
  alias Engram.Mailer
  alias Engram.Repo
  alias Engram.UsageMeters

  require Logger

  @days_60 60
  @days_80 80
  @days_90 90
  @hard_delete_after_days 30

  # Conservative SQL pre-filter for the soft-delete sweep. Per-user
  # `inactivity_delete_days` is then applied in Elixir; this floor just
  # avoids loading every user with a usage_meters row.
  @soft_delete_sql_floor_days 30

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    sweep_60_day_warning()
    sweep_80_day_warning()
    sweep_soft_delete()
    sweep_hard_delete()
    :ok
  end

  defp sweep_60_day_warning do
    cutoff = days_ago(@days_60)
    floor_cutoff = days_ago(@days_80)

    users =
      Repo.all(
        from(u in User,
          join: m in "usage_meters",
          on: m.user_id == u.id,
          where:
            is_nil(u.deleted_at) and
              is_nil(u.inactivity_warning_60_at) and
              m.last_active_at < ^cutoff and
              m.last_active_at >= ^floor_cutoff
        ),
        skip_tenant_check: true
      )

    Enum.each(users, fn user ->
      if warn_enabled?(user) do
        _ = Mailer.send_inactivity_warning_60(user)

        user
        |> Ecto.Changeset.change(%{inactivity_warning_60_at: DateTime.utc_now()})
        |> Repo.update!(skip_tenant_check: true)

        :telemetry.execute(
          [:engram, :abuse, :inactivity_warning],
          %{count: 1, days: @days_60},
          %{user_id: user.id}
        )
      end
    end)
  end

  defp sweep_80_day_warning do
    cutoff = days_ago(@days_80)
    floor_cutoff = days_ago(@days_90)

    users =
      Repo.all(
        from(u in User,
          join: m in "usage_meters",
          on: m.user_id == u.id,
          where:
            is_nil(u.deleted_at) and
              is_nil(u.inactivity_warning_80_at) and
              m.last_active_at < ^cutoff and
              m.last_active_at >= ^floor_cutoff
        ),
        skip_tenant_check: true
      )

    Enum.each(users, fn user ->
      if warn_enabled?(user) do
        _ = Mailer.send_inactivity_warning_80(user)

        user
        |> Ecto.Changeset.change(%{inactivity_warning_80_at: DateTime.utc_now()})
        |> Repo.update!(skip_tenant_check: true)

        :telemetry.execute(
          [:engram, :abuse, :inactivity_warning],
          %{count: 1, days: @days_80},
          %{user_id: user.id}
        )
      end
    end)
  end

  defp sweep_soft_delete do
    floor_cutoff = days_ago(@soft_delete_sql_floor_days)
    now = DateTime.utc_now()

    candidates =
      Repo.all(
        from(u in User,
          join: m in "usage_meters",
          on: m.user_id == u.id,
          where: is_nil(u.deleted_at) and m.last_active_at < ^floor_cutoff,
          select: {u, m.last_active_at}
        ),
        skip_tenant_check: true
      )

    Enum.each(candidates, fn {user, last_active_at} ->
      case delete_after_days(user) do
        days when is_integer(days) and days > 0 ->
          cutoff = DateTime.add(now, -days * 86_400, :second)
          if compare_lt?(last_active_at, cutoff), do: soft_delete(user)

        _ ->
          :skip
      end
    end)
  end

  # Raw column lands as NaiveDateTime when joined via string table name;
  # coerce to DateTime so the comparison works regardless of how the row
  # was selected.
  defp compare_lt?(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) == :lt

  defp compare_lt?(%NaiveDateTime{} = a, %DateTime{} = b),
    do: DateTime.compare(DateTime.from_naive!(a, "Etc/UTC"), b) == :lt

  defp soft_delete(user) do
    :ok = Lifecycle.soft_delete(user, :inactivity)

    :telemetry.execute(
      [:engram, :abuse, :inactivity_soft_delete],
      %{count: 1},
      %{user_id: user.id}
    )

    Logger.warning("Inactivity soft-delete fired",
      user_id: user.id,
      reason_label: :inactivity_90d
    )
  end

  defp sweep_hard_delete do
    cutoff = days_ago(@hard_delete_after_days)

    users =
      Repo.all(
        from(u in User, where: not is_nil(u.deleted_at) and u.deleted_at < ^cutoff),
        skip_tenant_check: true
      )

    Enum.each(users, &hard_delete/1)
  end

  defp hard_delete(user) do
    :ok = Lifecycle.hard_delete(user, :inactivity)

    :telemetry.execute(
      [:engram, :abuse, :inactivity_hard_delete],
      %{count: 1},
      %{user_id: user.id}
    )

    Logger.warning("Inactivity hard-delete fired",
      user_id: user.id,
      reason_label: :inactivity_120d
    )
  end

  defp warn_enabled?(user) do
    Billing.effective_limit(user, :inactivity_warn_60_days) == true
  end

  defp delete_after_days(user) do
    Billing.effective_limit(user, :inactivity_delete_days)
  end

  defp days_ago(days) do
    DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)
  end

  # Test-only: not used by Oban
  def days_60, do: @days_60
  def days_80, do: @days_80
  def days_90, do: @days_90
  def hard_delete_after_days, do: @hard_delete_after_days

  # Internal-but-exposed for tests that want to drive one sweep at a time
  # without spinning the whole perform/1.
  @doc false
  def __sweep_60__, do: sweep_60_day_warning()
  @doc false
  def __sweep_80__, do: sweep_80_day_warning()
  @doc false
  def __sweep_soft__, do: sweep_soft_delete()
  @doc false
  def __sweep_hard__, do: sweep_hard_delete()

  # Last_active is on usage_meters; UsageMeters wraps the read.
  @doc false
  def last_active(user_id), do: UsageMeters.last_active_at(user_id)
end
