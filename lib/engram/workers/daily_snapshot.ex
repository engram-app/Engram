defmodule Engram.Workers.DailySnapshot do
  @moduledoc """
  Daily cron for `Engram.Insights.Snapshot`: yesterday's account and vault
  snapshots, plus a rebuild of the last week's activity rollups. Idempotent
  (upserts keyed on id and date). Resumable: vaults are written in chunks,
  and a retry skips the chunks an earlier attempt wrote. Logs one summary
  line per run.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 3000]

  alias Engram.Insights.Snapshot
  alias Engram.Logger.Metadata

  require Logger

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  # The day is the one before the job was inserted, not before it runs, so a
  # retry after midnight still finishes the same day. `since` lets a retry
  # skip the vault chunks an earlier attempt (cut short by the timeout) wrote.
  @impl Oban.Worker
  def perform(%Oban.Job{inserted_at: inserted_at}) do
    {day, opts} =
      case inserted_at do
        %DateTime{} = at -> {Date.add(DateTime.to_date(at), -1), [since: at]}
        nil -> {Date.add(Date.utc_today(), -1), []}
      end

    %{date: day, users: users, healed: healed, vaults: vaults} =
      Snapshot.run([day: day] ++ opts)

    Logger.info(
      "daily_snapshot date=#{day} users=#{users} healed=#{healed} vaults=#{vaults}",
      Metadata.with_category(:info, :oban, [])
    )

    :ok
  end
end
