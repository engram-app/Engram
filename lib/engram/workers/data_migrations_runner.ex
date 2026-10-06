defmodule Engram.Workers.DataMigrationsRunner do
  @moduledoc """
  Hourly cron: one pass of every registered `Engram.DataMigration` whose
  ledger row is not done (`Engram.DataMigrations`). Each runs isolated: one
  raising does not stop the rest.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 3000]

  alias Engram.DataMigrations
  alias Engram.Logger.Metadata

  require Logger

  # Task 3-5 append their modules here.
  @migrations []

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(30)

  def migrations, do: @migrations

  @impl Oban.Worker
  def perform(_job) do
    Enum.each(@migrations, &run/1)
  end

  @spec run(module()) :: :skipped | :done | :more | :error
  def run(mod) do
    {name, version} = {mod.name(), mod.version()}

    if DataMigrations.done?(name, version) do
      :skipped
    else
      case mod.run_pass() do
        :done ->
          :ok = DataMigrations.mark_done(name, version)

          Logger.info(
            "data migration done",
            Metadata.with_category(:info, :oban, migration: name, version: version)
          )

          :done

        :more ->
          :more
      end
    end
  rescue
    e ->
      Logger.warning(
        "data migration pass failed",
        Metadata.with_category(:warning, :oban,
          migration: inspect(mod),
          reason: Metadata.safe_reason(e)
        )
      )

      :error
  end
end
