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

  alias Engram.Accounts.User
  alias Engram.Billing
  alias Engram.Mailer
  alias Engram.Repo
  alias Engram.Storage
  alias Engram.UsageMeters

  require Logger

  @days_60 60
  @days_80 80
  @days_90 90
  @hard_delete_after_days 30

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
      if free?(user) do
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
      if free?(user) do
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
    cutoff = days_ago(@days_90)

    users =
      Repo.all(
        from(u in User,
          join: m in "usage_meters",
          on: m.user_id == u.id,
          where: is_nil(u.deleted_at) and m.last_active_at < ^cutoff
        ),
        skip_tenant_check: true
      )

    Enum.each(users, fn user ->
      if free?(user) do
        soft_delete(user)
      end
    end)
  end

  defp soft_delete(user) do
    # Drop Qdrant points — vault rows survive so the audit trail stays.
    _ = drop_qdrant_for_user(user)

    user
    |> Ecto.Changeset.change(%{deleted_at: DateTime.utc_now()})
    |> Repo.update!(skip_tenant_check: true)

    _ = Mailer.send_account_deleted_notice(user)

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
    # Wipe attachments first so the FK cascade doesn't strand S3 objects.
    case Storage.adapter().delete_prefix("#{user.id}/") do
      {:ok, count} ->
        :telemetry.execute(
          [:engram, :abuse, :inactivity_hard_delete_objects],
          %{count: count},
          %{user_id: user.id}
        )

      {:error, reason} ->
        Logger.error("S3 prefix delete failed during hard-delete",
          user_id: user.id,
          reason: inspect(reason)
        )
    end

    Repo.delete!(user, skip_tenant_check: true)

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

  defp drop_qdrant_for_user(user) do
    # Best-effort: if Qdrant errors, log + continue. The soft-deleted user
    # can't query anyway; Qdrant leftovers self-resolve on hard-delete.
    case Engram.Vector.Qdrant.delete_by_user(user.id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Qdrant clear failed during soft-delete",
          user_id: user.id,
          reason: inspect(reason)
        )

        :error
    end
  rescue
    e ->
      Logger.error("Qdrant clear raised during soft-delete",
        user_id: user.id,
        exception: inspect(e)
      )

      :error
  end

  defp free?(user), do: Billing.tier(user) == :free

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
