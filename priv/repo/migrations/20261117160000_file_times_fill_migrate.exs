defmodule Engram.Repo.Migrations.FileTimesFillMigrate do
  use Ecto.Migration

  require Logger

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  R25 contract step (b): from this release no code reads or writes the
  epoch doubles (`notes.mtime` / `ctime`, `attachments.mtime`,
  `attachment_uploads.mtime`), and the `FileTimes` ledger that filled the
  `*_at` twins from them is gone. This fills the twins still NULL over a
  double, once, at boot: a self-hoster that skipped the releases that ran
  `FileTimes`, and on prod any row a 0.87 node wrote with a `0` (a NULL
  twin before step (a)) that step (a)'s walk had not reached. A set twin is
  never touched (beside a step (a) node a double may be stale; the twin is
  the authority).

  The value is `Engram.FileTime.normalize/1` in SQL (this module calls no
  app module: the N-1 gate runs migrations on the previous release's
  code): `0` is the epoch; below 1e11 in magnitude seconds, else
  milliseconds; rounded half away from zero to the microsecond and clamped
  into the value's own second; outside years 1 to 9999 (or past 1e16)
  NULL. It rounds the double's shortest round-trip decimal
  (`extra_float_digits = 1`), not its exact binary value, so a near-tie can
  land 1 us from `normalize/1` (readers accept that, `FileTime.twin?/2`).

  Every write is a window of at most #{5_000} rows in its own short
  transaction, so a cancel or a crash keeps the windows already done and
  the next boot only finishes the rest (it writes only NULL twins):

    * A connection that sees every tenant (a superuser or BYPASSRLS
      migrator, the usual self-host case, or one that may `SET ROLE
      engram_maintenance` with UPDATE and its `maintenance_all` policies,
      the `@visibility` test of 20261107120000) asks once per table whether
      any row needs a fill, and only then walks that table in primary-key
      windows: O(rows) in total, about 200 windows for 1M rows.
    * Otherwise (prod: `engram_admin`) one tenanted `EXISTS` per user, #{200}
      users per transaction, finds the users with work, and each is filled
      in its own tenant context, a window of matching rows at a time. Prod
      had 0 such rows on 2026-11-17 (all 1,852 tenants), so it runs the
      probe only.

  Each statement runs under a 5s `lock_timeout` and a 30s
  `statement_timeout`. A window locked out is retried twice; a user still
  locked out is retried once more after the others, and only then does the
  run raise (not recorded; the next boot resumes). A window past its
  timeout is halved, down to #{100} rows, before it raises.
  """

  @window 5_000
  @min_window 100
  @probe_batch 200
  @retries 2
  @statement_timeout "30s"
  @lock_timeout "5s"
  @contention [:lock_not_available, :deadlock_detected]
  @zero_id "00000000-0000-0000-0000-000000000000"

  @tables [
    {"notes", [mtime: :mtime_at, ctime: :ctime_at]},
    {"attachments", [mtime: :mtime_at]},
    {"attachment_uploads", [mtime: :mtime_at]}
  ]

  @visibility """
  SELECT
    (SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname = current_user),
    CASE WHEN to_regrole('engram_maintenance') IS NULL THEN false
      ELSE pg_has_role('engram_maintenance', 'SET')
        AND has_table_privilege('engram_maintenance', 'notes', 'SELECT, UPDATE')
        AND has_table_privilege('engram_maintenance', 'attachments', 'SELECT, UPDATE')
        AND has_table_privilege('engram_maintenance', 'attachment_uploads', 'SELECT, UPDATE')
        AND (SELECT count(*) = 3 FROM pg_policy
             WHERE polname = 'maintenance_all'
               AND polrelid IN ('notes'::regclass, 'attachments'::regclass,
                                'attachment_uploads'::regclass))
    END
  """

  def up, do: fill(repo())

  def down, do: :ok

  @doc false
  # The whole migration on `repo`. Tests pass `:before_window` (run inside
  # each window's transaction) and `:window`.
  def fill(repo, opts \\ []) do
    ctx = %{
      repo: repo,
      window: Keyword.get(opts, :window, @window),
      hook: Keyword.get(opts, :before_window, fn -> :ok end)
    }

    case repo.query!(@visibility).rows do
      [[true, _]] -> fill_all(Map.put(ctx, :role, nil))
      [[_, true]] -> fill_all(Map.put(ctx, :role, "engram_maintenance"))
      _ -> fill_by_tenant(Map.put(ctx, :role, nil))
    end

    :ok
  end

  # ── every tenant visible: per table, a probe, then primary-key windows ──

  defp fill_all(ctx) do
    for {table, pairs} <- @tables, needs_all?(ctx, table, pairs) do
      case walk_ids(ctx, table, pairs, @zero_id, ctx.window, 0) do
        {:ok, filled} ->
          log("#{table}: #{filled} twin(s) filled")

        :contention ->
          raise "file times fill: #{table} locked out after retries; the next boot resumes"
      end
    end
  end

  defp needs_all?(ctx, table, pairs) do
    tx(ctx, nil, fn ->
      %{rows: [[any?]]} =
        ctx.repo.query!("SELECT EXISTS (SELECT 1 FROM #{table} WHERE #{need(pairs)})")

      any?
    end)
  end

  defp walk_ids(ctx, table, pairs, after_id, size, filled) do
    sql = """
    WITH w AS (SELECT id FROM #{table} WHERE id > $1::uuid ORDER BY id LIMIT $2),
    u AS (UPDATE #{table} t SET #{sets(pairs)} FROM w WHERE t.id = w.id AND (#{need(pairs)}) RETURNING 1)
    SELECT (SELECT id::text FROM w ORDER BY id DESC LIMIT 1), (SELECT count(*) FROM u)
    """

    case window(ctx, nil, sql, [after_id, size], size) do
      {:ok, [[nil, n]]} -> {:ok, filled + n}
      {:ok, [[last, n]]} -> walk_ids(ctx, table, pairs, last, ctx.window, filled + n)
      {:smaller, half} -> walk_ids(ctx, table, pairs, after_id, half, filled)
      :contention -> :contention
    end
  end

  # ── tenant path: probe users in batches, fill each in its own context ──

  defp fill_by_tenant(ctx) do
    %{rows: rows} = ctx.repo.query!("SELECT id FROM users ORDER BY id")

    pending =
      rows
      |> Enum.map(fn [id] -> Ecto.UUID.cast!(id) end)
      |> Enum.chunk_every(@probe_batch)
      |> Enum.flat_map(&probe(ctx, &1))

    log("#{length(pending)} of #{length(rows)} users need a fill")

    left =
      pending
      |> Enum.reject(&(fill_user(ctx, &1) == :ok))
      |> Enum.reject(&(fill_user(ctx, &1) == :ok))

    if left != [] do
      raise "file times fill: #{length(left)} user(s) locked out after retries; " <>
              "not recording, the next boot resumes"
    end
  end

  defp probe(ctx, users) do
    case attempt(fn ->
           tx(ctx, nil, fn ->
             Enum.filter(users, fn user ->
               set_tenant(ctx, user)

               %{rows: [[any?]]} =
                 ctx.repo.query!(
                   "SELECT " <>
                     Enum.map_join(@tables, " OR ", fn {t, p} ->
                       "EXISTS (SELECT 1 FROM #{t} WHERE user_id = $1::uuid AND (#{need(p)}))"
                     end),
                   [user]
                 )

               any?
             end)
           end)
         end) do
      :contention -> users
      needing -> needing
    end
  end

  defp fill_user(ctx, user) do
    Enum.reduce_while(@tables, :ok, fn {table, pairs}, :ok ->
      case walk_user(ctx, user, table, pairs, ctx.window) do
        :ok -> {:cont, :ok}
        :contention -> {:halt, :contention}
      end
    end)
  end

  # Matching rows only, a window at a time: filled rows stop matching.
  defp walk_user(ctx, user, table, pairs, size) do
    sql = """
    WITH w AS (SELECT id FROM #{table} WHERE user_id = $1::uuid AND (#{need(pairs)}) LIMIT $2)
    UPDATE #{table} t SET #{sets(pairs)} FROM w WHERE t.id = w.id
    """

    case window(ctx, user, sql, [user, size], size, :num_rows) do
      {:ok, n} when n < size -> :ok
      {:ok, _} -> walk_user(ctx, user, table, pairs, ctx.window)
      {:smaller, half} -> walk_user(ctx, user, table, pairs, half)
      :contention -> :contention
    end
  end

  # ── one window: its own transaction, retried on contention, halved on a timeout ──

  defp window(ctx, user, sql, params, size, result \\ :rows) do
    attempt(fn ->
      tx(ctx, user, fn ->
        ctx.hook.()
        Map.fetch!(ctx.repo.query!(sql, params), result)
      end)
    end)
    |> case do
      :contention -> :contention
      value -> {:ok, value}
    end
  rescue
    e in Postgrex.Error ->
      cond do
        e.postgres[:code] != :query_canceled -> reraise(e, __STACKTRACE__)
        size > @min_window -> {:smaller, div(size, 2)}
        true -> reraise(e, __STACKTRACE__)
      end
  end

  @doc false
  # `fun.()`, retried twice on lock contention; `:contention` after that.
  def attempt(fun, retries \\ @retries) do
    fun.()
  rescue
    e in Postgrex.Error ->
      cond do
        not contention?(e) -> reraise(e, __STACKTRACE__)
        retries > 0 -> attempt(fun, retries - 1)
        true -> :contention
      end
  end

  defp contention?(%Postgrex.Error{postgres: %{code: code}}), do: code in @contention
  defp contention?(_), do: false

  # One short transaction, in `user`'s tenant context when given and as
  # `ctx.role` when set; both are cleared before it ends (a test runs this
  # in a sandbox, where they would outlive a savepoint).
  defp tx(ctx, user, fun) do
    {:ok, result} =
      ctx.repo.transaction(
        fn ->
          ctx.repo.query!(
            "SELECT set_config('lock_timeout', '#{@lock_timeout}', true), " <>
              "set_config('statement_timeout', '#{@statement_timeout}', true), " <>
              "set_config('extra_float_digits', '1', true)"
          )

          if ctx.role, do: ctx.repo.query!("SET LOCAL ROLE #{ctx.role}")
          if user, do: set_tenant(ctx, user)
          result = fun.()
          ctx.repo.query!("SELECT set_config('app.current_tenant', '', true)")
          if ctx.role, do: ctx.repo.query!("SELECT set_config('role', 'none', true)")
          result
        end,
        timeout: 60_000
      )

    result
  end

  defp set_tenant(ctx, user),
    do: ctx.repo.query!("SELECT set_config('app.current_tenant', $1, true)", [user])

  defp need(pairs),
    do: Enum.map_join(pairs, " OR ", fn {d, at} -> "(#{at} IS NULL AND #{d} IS NOT NULL)" end)

  defp sets(pairs),
    do:
      Enum.map_join(pairs, ", ", fn {d, at} ->
        "#{at} = COALESCE(t.#{at}, #{normalized_sql("t.#{d}")})"
      end)

  # Counts only, never a user id; `:boot` info lines ship to Loki.
  defp log(message),
    do: Logger.info("file times fill: #{message}", category: :boot, loki_ship: true)

  @doc false
  # The column `x` normalized: the twin `Engram.FileTime.normalize/1` gives.
  def normalized_sql(x) do
    s =
      "(CASE WHEN abs(#{x}) < 1e11 THEN #{x}::text::numeric ELSE #{x}::text::numeric / 1000 END)"

    us =
      "LEAST(GREATEST(round(#{s} * 1000000), floor(#{s}) * 1000000), floor(#{s}) * 1000000 + 999999)"

    """
    CASE
      WHEN #{x} = 0 THEN 'epoch'::timestamptz
      WHEN abs(#{x}) > 1e16 THEN NULL
      WHEN #{us} NOT BETWEEN -62135596800000000 AND 253402300799999999 THEN NULL
      ELSE 'epoch'::timestamptz
        + make_interval(secs => floor(#{us} / 1000000)::float8)
        + make_interval(secs => (#{us} - floor(#{us} / 1000000) * 1000000)::float8 / 1000000)
    END
    """
  end
end
