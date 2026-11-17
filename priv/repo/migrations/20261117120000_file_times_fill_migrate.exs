defmodule Engram.Repo.Migrations.FileTimesFillMigrate do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  R25 contract step (b): from this release no code reads or writes the
  epoch doubles (`notes.mtime` / `ctime`, `attachments.mtime`,
  `attachment_uploads.mtime`), and the `FileTimes` ledger that filled the
  `*_at` twins from them is gone. This fills the twins that are still NULL
  over a double, once, at boot: a self-hoster that skipped the releases
  that ran `FileTimes`, and on prod the few rows a 0.87 node wrote with a
  `0` (NULL twin before 0.88, the epoch since) before step (a)'s walk
  reached them. A set twin is never touched (beside a step (a) node the
  double may be stale, and the twin is the authority).

  The value is `Engram.FileTime.normalize/1` in SQL, which this module
  must not call (the N-1 gate runs migrations on the previous release's
  code): `0` is the epoch; below 1e11 in magnitude seconds, else
  milliseconds; rounded half away from zero to the microsecond and clamped
  into the value's own second; outside years 1 to 9999 (or past 1e16)
  NULL. It rounds the double's shortest round-trip decimal
  (`extra_float_digits = 1`), not its exact binary value, so a near-tie can
  land 1 us from `normalize/1`; readers accept a twin within 1 us of a
  double (`FileTime.twin?/2`), and the doubles are dropped next.

  Per user, one short transaction under the user's tenant context (no RLS
  bypass, no table lock), `lock_timeout` 5s, `statement_timeout` 60s. A
  failure raises and the next boot reruns it (rerun-safe: it writes only
  NULL twins). Prod (2026-11-17): about 1.6k users, near zero rows to fill.
  """

  @tables [
    {"notes", [mtime: :mtime_at, ctime: :ctime_at]},
    {"attachments", [mtime: :mtime_at]},
    {"attachment_uploads", [mtime: :mtime_at]}
  ]

  def up, do: fill(repo())

  def down, do: :ok

  @doc false
  # Every user's NULL twins; `repo` is the migration's (tests pass theirs).
  def fill(repo) do
    %{rows: users} = repo.query!("SELECT id FROM users ORDER BY id", [])

    for [id] <- users do
      {:ok, _} =
        repo.transaction(fn ->
          tenant = Ecto.UUID.cast!(id)
          repo.query!("SELECT set_config('app.current_tenant', $1, true)", [tenant])
          repo.query!("SET LOCAL lock_timeout = '5s'", [])
          repo.query!("SET LOCAL statement_timeout = '60s'", [])
          repo.query!("SET LOCAL extra_float_digits = 1", [])
          for {table, pairs} <- @tables, do: repo.query!(fill_sql(table, pairs), [id])
        end)
    end

    :ok
  end

  defp fill_sql(table, pairs) do
    sets = Enum.map_join(pairs, ", ", fn {d, at} -> "#{at} = COALESCE(#{at}, #{normalized_sql(d)})" end)
    need = Enum.map_join(pairs, " OR ", fn {d, at} -> "(#{at} IS NULL AND #{d} IS NOT NULL)" end)
    "UPDATE #{table} SET #{sets} WHERE user_id = $1 AND (#{need})"
  end

  @doc false
  # The column `x` normalized: the twin `Engram.FileTime.normalize/1` gives.
  def normalized_sql(x) do
    s = "(CASE WHEN abs(#{x}) < 1e11 THEN #{x}::text::numeric ELSE #{x}::text::numeric / 1000 END)"
    us = "LEAST(GREATEST(round(#{s} * 1000000), floor(#{s}) * 1000000), floor(#{s}) * 1000000 + 999999)"

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
