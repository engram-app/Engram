defmodule Engram.Backfill.Throttle do
  @moduledoc """
  The database guard every paced backfill chain shares (`NameTerms`,
  `NoteName`): a writes-per-second ceiling inside a hop, and a pressure gate
  before one. The 2026-11-01 prod RDS swap came from this shape of job (a
  walk writing hundreds of rows a second on a 4 GB instance;
  `docs/context/maintenance-job-db-load.md`).

    * `wait_ms/5`: after a window, how long to sleep so the hop's writes
      stay at or under its ceiling (and never less than the chain's pause).
      Pure, so a test drives it with its own clock.
    * `pressure/1`: one probe on the app pool, timed. Its wall time is the
      pool queue plus a round trip; its result is the age of the oldest open
      client transaction (pg_stat_activity; a role sees only the
      `xact_start` of its own role's sessions, so this is the app's and the
      maintenance pool's own long transactions). Either over its bound
      (`backfill_max_queue_ms`, default #{200}; `backfill_max_xact_s`,
      default #{120}) holds the hop: the chain re-inserts it later and
      writes nothing now.
    * `positive/2`: a positive-integer service setting, falling back to
      its default (with a warning) on a bad env value.

  The bounds are a starting guess, not measured on prod; tune them through
  `Engram.ServiceConfig` without a deploy.
  """

  alias Engram.DataMigration
  alias Engram.Logger.Metadata
  alias Engram.ServiceConfig

  require Logger

  @max_queue_ms 200
  @max_xact_s 120

  @oldest_xact_sql """
  SELECT COALESCE(EXTRACT(EPOCH FROM now() - min(xact_start)), 0)::int
  FROM pg_stat_activity
  WHERE xact_start IS NOT NULL
    AND backend_type = 'client backend'
    AND datname = current_database()
    AND pid <> pg_backend_pid()
  """

  @doc """
  Milliseconds to sleep after a window so that `writes` written since
  `started_ms` (both on the `now_ms/0` clock) stay at or under `per_s` a
  second. Never less than `pause_ms`.
  """
  @spec wait_ms(integer(), non_neg_integer(), pos_integer(), non_neg_integer(), integer()) ::
          non_neg_integer()
  def wait_ms(started_ms, writes, per_s, pause_ms, now_ms),
    do: max(pause_ms, started_ms + div(writes * 1000 + per_s - 1, per_s) - now_ms)

  @doc "The clock `wait_ms/5` reads in production (monotonic ms)."
  @spec now_ms() :: integer()
  def now_ms, do: System.monotonic_time(:millisecond)

  @doc """
  nil when the database has room for a hop of `backfill` (a name for the
  log line), else why not: `:pool_queue` or `:long_xact`, logged.
  """
  @spec pressure(String.t()) :: nil | :pool_queue | :long_xact
  def pressure(backfill) do
    %{queue_ms: queue_ms, xact_s: xact_s} = reader().read(Engram.Repo)

    reason =
      cond do
        queue_ms > positive(:backfill_max_queue_ms, @max_queue_ms) -> :pool_queue
        xact_s > positive(:backfill_max_xact_s, @max_xact_s) -> :long_xact
        true -> nil
      end

    if reason do
      Logger.info(
        "backfill hop held on database pressure",
        DataMigration.progress_metadata(
          backfill: backfill,
          reason_label: reason,
          queue_ms: queue_ms,
          xact_s: xact_s
        )
      )
    end

    reason
  end

  @doc "One timed probe: pool queue plus round trip (ms), oldest open transaction (s)."
  @spec read(module()) :: %{queue_ms: non_neg_integer(), xact_s: non_neg_integer()}
  def read(repo) do
    {us, %{rows: [[age]]}} = :timer.tc(fn -> repo.query!(@oldest_xact_sql) end)
    %{queue_ms: div(us, 1000), xact_s: age}
  end

  # Tests swap in a fixed reading (config/test.exs).
  defp reader, do: Application.get_env(:engram, :backfill_pressure_reader, __MODULE__)

  @doc "The service setting `key` when it is a positive integer, else `default`."
  @spec positive(atom(), pos_integer()) :: pos_integer()
  def positive(key, default) do
    case ServiceConfig.get(key, default) do
      n when is_integer(n) and n > 0 ->
        n

      _ ->
        Logger.warning(
          "#{key} is not a positive integer, using #{default}",
          Metadata.with_category(:warning, :data)
        )

        default
    end
  end
end
