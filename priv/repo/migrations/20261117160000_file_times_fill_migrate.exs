defmodule Engram.Repo.Migrations.FileTimesFillMigrate do
  use Ecto.Migration

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

  Cost, bounded well under the boot budget at prod size (1,806 users):
  first one probe. A connection that sees every tenant (a superuser or
  BYPASSRLS migrator, or one that may `SET ROLE engram_maintenance` with
  its `maintenance_all` policies, the `@visibility` test of 20261107120000)
  asks once per table whether any row needs a fill and, when one does,
  fills with one set-based UPDATE per table. Otherwise users go in batches
  of #{200}, one short transaction per batch, whose server-side `DO` block
  sets each user's tenant and runs the three UPDATEs: about 10 batches and
  40 round trips at prod size, not one transaction per user. Each batch
  runs under a 5s `lock_timeout` and a 30s `statement_timeout`; a batch
  that hits a lock timeout is retried twice, then once more after every
  other batch, and only then does the run raise (not recorded, the next
  boot resumes; rerun-safe, it writes only NULL twins). Nothing starts
  after #{60} s. Prod (2026-11-16): `file_times` closed at 10:33Z, so near
  zero rows to fill.
  """

  @batch 200
  @retries 2
  @deadline_ms 60_000
  @statement_timeout "30s"
  @lock_timeout "5s"
  @contention [:lock_not_available, :deadlock_detected]

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
        AND (SELECT count(*) = 3 FROM pg_policy
             WHERE polname = 'maintenance_all'
               AND polrelid IN ('notes'::regclass, 'attachments'::regclass,
                                'attachment_uploads'::regclass))
    END
  """

  def up, do: fill(repo())

  def down, do: :ok

  @doc false
  # The whole migration on `repo`; tests pass theirs and `:deadline_ms`.
  def fill(repo, opts \\ []) do
    deadline = now() + Keyword.get(opts, :deadline_ms, @deadline_ms)

    case repo.query!(@visibility).rows do
      [[true, _]] -> fill_all(repo, nil, deadline)
      [[_, true]] -> fill_all(repo, "engram_maintenance", deadline)
      _ -> fill_by_tenant(repo, deadline)
    end

    :ok
  end

  # One set-based UPDATE per table that needs any, on a connection that
  # sees every row.
  defp fill_all(repo, role, deadline) do
    attempt(fn ->
      tx(repo, role, deadline, fn ->
        for {table, pairs} <- @tables,
            needs?(repo, table, pairs),
            do: repo.query!(fill_sql(table, pairs, ""))
      end)
    end)
    |> case do
      :ok ->
        :ok

      :contention ->
        raise "file times fill: locked out after #{@retries} retries; the next boot resumes"
    end
  end

  defp needs?(repo, table, pairs) do
    %{rows: [[any?]]} =
      repo.query!("SELECT EXISTS (SELECT 1 FROM #{table} WHERE #{need(pairs)})")

    any?
  end

  defp fill_by_tenant(repo, deadline) do
    %{rows: rows} = repo.query!("SELECT id FROM users ORDER BY id")
    batches = rows |> Enum.map(fn [id] -> Ecto.UUID.cast!(id) end) |> Enum.chunk_every(@batch)

    left =
      batches
      |> Enum.reject(&(run_batch(repo, &1, deadline) == :ok))
      |> Enum.reject(&(run_batch(repo, &1, deadline) == :ok))

    if left != [] do
      raise "file times fill: #{length(left)} batch(es) of #{@batch} users locked out or " <>
              "past the deadline; not recording, the next boot resumes"
    end
  end

  defp run_batch(repo, users, deadline) do
    if now() > deadline,
      do: :late,
      else: attempt(fn -> tx(repo, nil, deadline, fn -> repo.query!(do_block(users)) end) end)
  end

  # `fun` with retries on lock contention: `:ok` or `:contention`.
  defp attempt(fun, retries \\ @retries) do
    fun.()
    :ok
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

  # One short transaction; the role and tenant are cleared before it ends
  # (a test runs this in a sandbox, where they would outlive a savepoint).
  defp tx(repo, role, deadline, fun) do
    {:ok, _} =
      repo.transaction(
        fn ->
          repo.query!(
            "SELECT set_config('lock_timeout', '#{@lock_timeout}', true), " <>
              "set_config('statement_timeout', '#{@statement_timeout}', true), " <>
              "set_config('extra_float_digits', '1', true)"
          )

          if role, do: repo.query!("SET LOCAL ROLE #{role}")
          fun.()
          repo.query!("SELECT set_config('app.current_tenant', '', true)")
          if role, do: repo.query!("SELECT set_config('role', 'none', true)")
        end,
        timeout: max(deadline - now(), 0) + 40_000
      )

    :ok
  end

  # Each user's tenant, then the three fills, server-side: one round trip
  # per batch. The ids come from `users` and are cast as UUIDs above.
  defp do_block(users) do
    ids = Enum.map_join(users, ",", &"'#{&1}'")

    fills =
      Enum.map_join(@tables, "\n", fn {t, p} -> fill_sql(t, p, "AND user_id = u") <> ";" end)

    """
    DO $fill$
    DECLARE u uuid;
    BEGIN
      FOREACH u IN ARRAY ARRAY[#{ids}]::uuid[] LOOP
        PERFORM set_config('app.current_tenant', u::text, true);
        #{fills}
      END LOOP;
    END
    $fill$
    """
  end

  defp need(pairs),
    do: Enum.map_join(pairs, " OR ", fn {d, at} -> "(#{at} IS NULL AND #{d} IS NOT NULL)" end)

  defp fill_sql(table, pairs, scope) do
    sets =
      Enum.map_join(pairs, ", ", fn {d, at} -> "#{at} = COALESCE(#{at}, #{normalized_sql(d)})" end)

    "UPDATE #{table} SET #{sets} WHERE (#{need(pairs)}) #{scope}"
  end

  defp now, do: System.monotonic_time(:millisecond)

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
