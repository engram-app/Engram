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
    * `pressure/0`: one probe on the app pool, timed. The PRIMARY signal is
      its wall time, the pool queue plus a round trip (`backfill_max_queue_ms`,
      default #{200}): it sees load from every source. The secondary one is
      the age of the oldest open client transaction (`backfill_max_xact_s`,
      default #{120}), but pg_stat_activity shows `xact_start` only for the
      caller's own role's sessions unless the role holds `pg_monitor` /
      `pg_read_all_stats`, and `engram_app` holds neither (engram-infra
      main: only `engram_metrics_ro` and `engram_audit_ro` do). So a long
      transaction from another role (`engram_maintenance`, `engram_audit_ro`,
      a bastion session) is invisible to this gate; the infra
      `pg_long_xact` alert covers those. Either over its bound holds the
      hop: the chain re-inserts it later and writes nothing now.
    * `log_pass/2`: the one summary line per pass.
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
  nil when the database has room for a hop, else why not: `:pool_queue` or
  `:long_xact`. The caller reports it in its `log_pass/2` line.
  """
  @spec pressure() :: nil | :pool_queue | :long_xact
  def pressure do
    %{queue_ms: queue_ms, xact_s: xact_s} = reader().read(Engram.Repo)

    cond do
      queue_ms > positive(:backfill_max_queue_ms, @max_queue_ms) -> :pool_queue
      xact_s > positive(:backfill_max_xact_s, @max_xact_s) -> :long_xact
      true -> nil
    end
  end

  @doc """
  The one summary line of a backfill pass (a chain hop): counts, the hold
  reason and timing only, never an id. `fields`: `written` (rows written),
  `held` (the `pressure/0` reason, or `:none`), `elapsed_ms`, plus whatever
  the chain can count cheaply (`left_est`, `walk_left`, `result`).
  """
  @spec log_pass(String.t(), keyword()) :: :ok
  def log_pass(backfill, fields) do
    Logger.info(
      "backfill pass",
      DataMigration.progress_metadata([backfill: backfill] ++ fields)
    )
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
