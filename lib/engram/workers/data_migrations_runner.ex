defmodule Engram.Workers.DataMigrationsRunner do
  @moduledoc """
  Hourly cron: one pass of every registered `Engram.DataMigration` whose
  ledger row is not done (`Engram.DataMigrations`). Each runs isolated: one
  raising, exiting or throwing does not stop the rest.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 3000]

  alias Engram.DataMigrations
  alias Engram.Logger.Metadata

  require Logger

  @stuck_after_s 7 * 86_400
  @realert_after_s 86_400

  # Register every Engram.DataMigration here.
  @migrations [Engram.DataMigrations.IndexVersions, Engram.DataMigrations.CrdtStateSeed]

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(30)

  def migrations, do: @migrations

  @impl Oban.Worker
  def perform(_job) do
    Enum.each(@migrations, &run/1)
  end

  # A failure here, before any pass ran (name/0, version/0, the done?/2 read),
  # says nothing about the migration's work, so it must not touch the ledger:
  # note_open/2 would reopen a DONE row.
  @spec run(module()) :: :skipped | :done | :more | :error
  def run(mod) do
    {name, version} = {mod.name(), mod.version()}
    if DataMigrations.done?(name, version), do: :skipped, else: pass(mod, name, version)
  rescue
    e -> failed(mod, e)
  catch
    # An exit (a call or checkout timeout) or a throw must not abort the
    # migrations after this one either.
    _kind, reason -> failed(mod, reason)
  end

  # The pass ran: :more or a failure both leave the work open.
  defp pass(mod, name, version) do
    case mod.run_pass() do
      :done ->
        :ok = DataMigrations.mark_done(name, version)

        Logger.info(
          "data migration done",
          Metadata.with_category(:info, :oban, migration: name, version: version)
        )

        :done

      :more ->
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

  # Open longer than @stuck_after_s: one :error log (Sentry) per migration per
  # 24 h so a human reviews it. Never lets a ledger failure break the pass.
  defp flag_if_stuck(name, version) do
    entry = DataMigrations.note_open(name, version)
    now = DateTime.utc_now()

    if DateTime.diff(now, entry.opened_at) > @stuck_after_s and
         (is_nil(entry.alerted_at) or DateTime.diff(now, entry.alerted_at) > @realert_after_s) do
      Logger.error(
        "data migration stuck: #{name} v#{version} open since #{DateTime.to_iso8601(entry.opened_at)}",
        Metadata.with_category(:error, :oban,
          migration: name,
          version: version,
          opened_at: DateTime.to_iso8601(entry.opened_at)
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
