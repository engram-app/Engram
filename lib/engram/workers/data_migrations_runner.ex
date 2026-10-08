defmodule Engram.Workers.DataMigrationsRunner do
  @moduledoc """
  Hourly cron: one pass of every registered `Engram.DataMigration` whose
  ledger row is not done (`Engram.DataMigrations`). Each runs isolated: one
  raising, exiting or throwing does not stop the rest.
  """
  # `states: :incomplete`: two runs never overlap, but a finished run does not
  # swallow the next one. The default (:successful) would dedupe the @reboot run
  # against an hourly run that COMPLETED within the period.
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 3000, states: :incomplete]

  alias Engram.DataMigrations
  alias Engram.Logger.Metadata

  require Logger

  # The hourly run in this UTC hour also re-runs done migrations that opt in
  # with `reverify?/0`. Same hour as ReconcileEmbeddings' IndexVersions check.
  # Catch-up: a done row whose last verification (`completed_at`, which every
  # :done re-verify rewrites) is older than @reverify_stale_s is re-verified
  # on the next hourly run, so a deduped or failed 04:00 run does not skip a day.
  @reverify_hour 4
  @reverify_stale_s 25 * 3600
  @stuck_after_s 7 * 86_400
  @realert_after_s 86_400

  # Register every Engram.DataMigration here.
  @migrations [
    Engram.DataMigrations.IndexVersions,
    Engram.DataMigrations.CrdtStateSeed,
    Engram.DataMigrations.EnvelopeFormat
  ]

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(30)

  def migrations, do: @migrations

  @impl Oban.Worker
  def perform(%Oban.Job{scheduled_at: scheduled_at}) do
    reverify = match?(%DateTime{hour: @reverify_hour}, scheduled_at)
    Enum.each(@migrations, &run(&1, reverify))
  end

  # A failure here, before any pass ran (name/0, version/0, the done?/2 read),
  # says nothing about the migration's work, so it must not touch the ledger:
  # note_open/2 would reopen a DONE row.
  #
  # A disabled migration runs no pass and is never opened, alerted on or marked
  # done; only an ALREADY open row has its stuck clock held (see disabled/1). A done
  # one is skipped too, except when it opts in and the re-verify is due (04:00
  # UTC, or its last verification is over 25 h old): then its
  # pass runs, and `:more` reopens it (note_open/2 clears completed_at).
  @spec run(module(), boolean()) :: :skipped | :done | :more | :error
  def run(mod, reverify \\ false) do
    {name, version} = {mod.name(), mod.version()}

    cond do
      not optional(mod, :enabled?, true) ->
        disabled(name)

      not DataMigrations.done?(name, version) ->
        pass(mod, name, version)

      optional(mod, :reverify?, false) and reverify_due?(name, reverify) ->
        reverify(mod, name, version)

      true ->
        :skipped
    end
  rescue
    e -> failed(mod, e)
  catch
    # An exit (a call or checkout timeout) or a throw must not abort the
    # migrations after this one either.
    _kind, reason -> failed(mod, reason)
  end

  defp reverify_due?(_name, true), do: true

  defp reverify_due?(name, false),
    do:
      DataMigrations.verified_before?(name, DateTime.add(DateTime.utc_now(), -@reverify_stale_s))

  defp optional(mod, fun, default) do
    _ = Code.ensure_loaded(mod)
    if function_exported?(mod, fun, 0), do: apply(mod, fun, []), else: default
  end

  # Disabled time is not stuck time: an open row's clock is held at "now" on
  # every disabled run, so re-enabling never pages for the disabled span.
  defp disabled(name) do
    :ok = DataMigrations.hold_clock(name)
    :skipped
  end

  # Done already: only a pass that finds work changes anything.
  #
  # A reopen is :info, not :warning: it is routine (EnvelopeFormat reopens
  # most days from rows written while a rolling deploy blocked the
  # compression gate), and a daily :warning would hide a real one. The found
  # count rides along (in the message, so Loki shows it) to tell a few
  # deploy-window rows from a fleet-wide regression. The abnormal cases have
  # their own signals: a pass that raises (:warning below), work that never
  # finishes (the stuck alert), and for EnvelopeFormat the compression gate
  # gauge and the undecryptable-row :warning.
  defp reverify(mod, name, version) do
    case run_pass(mod) do
      # Idempotent. Normally a no-op; it closes a row a re-verify reopened
      # while this node still cached `done?` (another node's reopen).
      :done ->
        :ok = DataMigrations.mark_done(name, version)
        :done

      {:more, found} ->
        DataMigrations.reopen(name, version)

        Logger.info(
          "data migration reopened by re-verify#{describe(found)}",
          Metadata.with_category(:info, :oban, [migration: name, version: version] ++ found)
        )

        :more
    end
  end

  defp run_pass(mod) do
    case mod.run_pass() do
      :done -> :done
      :more -> {:more, []}
      {:more, found} when is_list(found) -> {:more, found}
    end
  end

  defp describe([]), do: ""
  defp describe(found), do: ": found " <> Enum.map_join(found, " ", fn {k, v} -> "#{k}=#{v}" end)

  # The pass ran: :more or a failure both leave the work open.
  defp pass(mod, name, version) do
    case run_pass(mod) do
      :done ->
        :ok = DataMigrations.mark_done(name, version)

        Logger.info(
          "data migration done",
          Metadata.with_category(:info, :oban, migration: name, version: version)
        )

        :done

      {:more, _found} ->
        flag_if_stuck(name, version)
        :more
    end
  rescue
    e ->
      flag_if_stuck(name, version)
      failed(mod, e)
  catch
    _kind, reason ->
      flag_if_stuck(name, version)
      failed(mod, reason)
  end

  # Open longer than @stuck_after_s: once per migration per 24 h, a Sentry
  # message (capture_log_messages is off, so a Logger.error alone never reaches
  # Sentry) plus an :error log for Loki, so a human reviews it. Never lets a
  # ledger failure break the pass.
  defp flag_if_stuck(name, version) do
    entry = DataMigrations.note_open(name, version)
    now = DateTime.utc_now()

    if DateTime.diff(now, entry.opened_at) > @stuck_after_s and
         (is_nil(entry.alerted_at) or DateTime.diff(now, entry.alerted_at) > @realert_after_s) do
      opened_at = DateTime.to_iso8601(entry.opened_at)
      message = "data migration stuck: #{name} v#{version} open since #{opened_at}"

      _ =
        Sentry.capture_message(message,
          extra: %{migration: name, version: version, opened_at: opened_at}
        )

      Logger.error(
        message,
        Metadata.with_category(:error, :oban,
          migration: name,
          version: version,
          opened_at: opened_at
        )
      )

      DataMigrations.mark_alerted(name)
    end
  rescue
    e ->
      Logger.warning(
        "data migration stuck check failed",
        Metadata.with_category(:warning, :oban, migration: name, reason: Metadata.safe_reason(e))
      )
  end

  defp failed(mod, reason) do
    Logger.warning(
      "data migration pass failed",
      Metadata.with_category(:warning, :oban,
        migration: ledger_name(mod),
        reason: Metadata.safe_reason(reason)
      )
    )

    :error
  end

  # The failure being logged may be name/0 itself.
  defp ledger_name(mod) do
    mod.name()
  catch
    _kind, _reason -> inspect(mod)
  end
end
