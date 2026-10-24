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
  alias Engram.Logger.Metadata
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
  def timeout(_job), do: :timer.minutes(15)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    sweep_60_day_warning()
    sweep_80_day_warning()
    sweep_soft_delete()
    sweep_hard_delete()
    :ok
  end

  defp sweep_60_day_warning do
    sweep_warning(
      @days_60,
      @days_80,
      :warning_60,
      :inactivity_warning_60_at,
      &Mailer.send_inactivity_warning_60/1
    )
  end

  defp sweep_80_day_warning do
    sweep_warning(
      @days_80,
      @days_90,
      :warning_80,
      :inactivity_warning_80_at,
      &Mailer.send_inactivity_warning_80/1
    )
  end

  # Both warning rungs are the same sweep: find live users whose last activity
  # falls inside [floor_days, days) who haven't been stamped yet, mail them,
  # stamp `warned_field`. The floor keeps the rungs disjoint — a user already
  # past the next rung's threshold gets that rung's (sterner) email instead of
  # both.
  defp sweep_warning(days, floor_days, step, warned_field, mailer_fun) do
    cutoff = days_ago(days)
    floor_cutoff = days_ago(floor_days)

    users =
      Repo.all(
        from(u in User,
          join: m in "usage_meters",
          on: m.user_id == u.id,
          where:
            is_nil(u.deleted_at) and
              is_nil(field(u, ^warned_field)) and
              m.last_active_at < ^cutoff and
              m.last_active_at >= ^floor_cutoff
        ),
        skip_tenant_check: true
      )

    Enum.each(users, fn user ->
      if warn_enabled?(user),
        do: per_user(user, step, fn -> warn(user, days, warned_field, mailer_fun) end)
    end)
  end

  defp warn(user, days, warned_field, mailer_fun) do
    _ = mailer_fun.(user)

    user
    |> Ecto.Changeset.change(%{warned_field => DateTime.utc_now()})
    |> Repo.update!(skip_tenant_check: true)

    :telemetry.execute(
      [:engram, :abuse, :inactivity_warning],
      %{count: 1, days: days},
      %{user_id: user.id}
    )
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

          if compare_lt?(last_active_at, cutoff),
            do: per_user(user, :soft_delete, fn -> soft_delete(user) end)

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

    Logger.warning(
      "Inactivity soft-delete fired",
      Metadata.with_category(:warning, :lifecycle,
        user_id: user.id,
        reason_label: :inactivity_90d
      )
    )
  end

  defp sweep_hard_delete do
    cutoff = days_ago(@hard_delete_after_days)

    users =
      Repo.all(
        from(u in User, where: not is_nil(u.deleted_at) and u.deleted_at < ^cutoff),
        skip_tenant_check: true
      )

    Enum.each(users, fn user -> per_user(user, :hard_delete, fn -> hard_delete(user) end) end)
  end

  # Every sweep's per-user step runs through here. One user's failure must not
  # abort the rest of the run: the sweeps only re-find users by state, so a
  # raise mid-loop leaves every later user for tomorrow, and a crash that
  # repeats daily (one bad row) starves them forever. Lifecycle itself still
  # raises, so a request-path caller (delete_self, the Clerk webhook) fails
  # loudly and its retry re-runs it.
  #
  # Catches what the step's own process raises, exits or throws (an exit from
  # a GenServer call that timed out, say). It does NOT catch a crash in a
  # process LINKED to this one: that kills the sweep job outright, and only
  # the next daily run picks the rest up.
  #
  # A step that returns `{:error, reason}` is a failure too (a hard delete that
  # rolled back, or refused the last admin), counted as kind `:error`. The sweep
  # still returns `:ok`: failing the job would make Oban retry the whole run and
  # resend every warning email. The counter is the signal, on
  # `Engram.PromEx.Reliability` (`..._inactivity_sweep_failed_total`, tags
  # `[:step, :kind]`); its alert is engram-infra#1584.
  defp per_user(user, step, fun) do
    case fun.() do
      {:error, reason} -> sweep_failed(user, step, :error, Metadata.safe_reason(reason))
      _ok -> :ok
    end
  catch
    kind, reason ->
      sweep_failed(
        user,
        step,
        kind,
        "#{Metadata.safe_reason(reason)} at=#{Metadata.format_location(__STACKTRACE__)}"
      )
  end

  # `reason` is already redacted: `safe_reason/1` for the value and
  # `format_location/1` (no argument values) for the stacktrace.
  defp sweep_failed(user, step, kind, reason) do
    :telemetry.execute(
      [:engram, :abuse, :inactivity_sweep_failed],
      %{count: 1},
      %{user_id: user.id, step: step, kind: kind}
    )

    Logger.error(
      "Inactivity sweep step failed for one user, continuing",
      Metadata.with_category(:error, :lifecycle,
        user_id: user.id,
        step: step,
        kind: kind,
        reason: reason
      )
    )

    :error
  end

  # `{:error, _}` is returned to `per_user/3`, which logs and counts it. That
  # includes `:last_admin`: a stranded last admin recurs daily until ops
  # promotes another admin, so it should stay visible on the counter.
  defp hard_delete(user) do
    with :ok <- Lifecycle.hard_delete(user, :inactivity) do
      :telemetry.execute(
        [:engram, :abuse, :inactivity_hard_delete],
        %{count: 1},
        %{user_id: user.id}
      )

      Logger.warning(
        "Inactivity hard-delete fired",
        Metadata.with_category(:warning, :lifecycle,
          user_id: user.id,
          reason_label: :inactivity_120d
        )
      )
    end
  end

  # Routes through the single source of truth rather than re-deriving it. The
  # key is grant-shaped (`true` == exempt), so enforcement-off (`:unlimited`)
  # means exempt and a self-hosted instance never sends free-tier dunning.
  defp warn_enabled?(user), do: not Billing.inactivity_warnings_exempt?(user)

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
