# squawk-ignore-file — schema-restore DDL; squawk parser does not handle the
# advanced syntax in a full structure dump (FORCE ROW LEVEL SECURITY,
# sequences, ALTER ... OWNER). The schema diff gate guards correctness.
#
# rollback-irreversible — `down` raises by design. There is no sensible
# reversal of "blow away everything and reinstall the dump." Pre-launch
# operation; redo by `mix ecto.drop && mix ecto.create && mix ecto.migrate`.
defmodule Engram.Repo.Migrations.Baseline do
  @moduledoc """
  Single baseline migration. Replaces 67 historical migrations collapsed on
  2026-06-02 before v1 prod launch. Source of truth is
  `priv/repo/structure.sql`, regenerable via:

      pg_dump --schema-only --no-owner --exclude-table=schema_migrations \\
              -U engram -d engram_test

  Both AWS prod (`app.engram.page`) and FastRaid staging
  (`staging.engram.page`) databases are wiped before this image deploys.
  Running against a non-empty schema fails because every `CREATE TABLE` in
  structure.sql is unconditional.

  Prerequisite: `Engram.Release.prepare_database/0` must run first.
  It creates the `engram_app` runtime role that the structure dump's
  GRANT statements reference. Cluster-scoped bootstrap was moved out
  of this migration so envs don't bake in role names (release task is
  CURRENT_USER-portable; the prior `ALTER DEFAULT PRIVILEGES FOR ROLE
  engram` in the dump assumed the dev superuser was named `engram`,
  which broke on RDS where the master is `engram_admin`).
  """

  use Ecto.Migration

  def up do
    path = Path.join(:code.priv_dir(:engram), "repo/structure.sql")

    path
    |> File.read!()
    |> split_statements()
    |> Enum.each(fn stmt -> repo().query!(stmt, []) end)
  end

  def down do
    raise "Baseline migration is irreversible"
  end

  # pg_dump output: top-level statements terminated by `;` at end of line,
  # comments are `--` lines, blank lines separate blocks. No function bodies
  # (`$$`) in this baseline — verified at collapse time. Splitting on
  # newline+semicolon is safe under that invariant.
  defp split_statements(sql) do
    sql
    |> String.split(~r/;\s*\n/, trim: true)
    |> Enum.map(&strip_comments_and_trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp strip_comments_and_trim(chunk) do
    chunk
    |> String.split("\n")
    |> Enum.reject(fn line ->
      trimmed = String.trim(line)
      # `--` SQL comments + PG18 pg_dump psql metacommands `\restrict` / `\unrestrict`
      # (security additions in PG18; not valid SQL — psql-only).
      String.starts_with?(trimmed, "--") or String.starts_with?(trimmed, "\\")
    end)
    |> Enum.join("\n")
    |> String.trim()
    |> drop_pg18_search_path_reset()
  end

  # PG18 pg_dump emits `SELECT pg_catalog.set_config('search_path', '', false);`
  # to prevent search_path injection during restore. We replay the dump inside
  # the migrator's existing connection, so wiping search_path here breaks the
  # ecto schema_migrations bookkeeping that runs immediately after this
  # migration. The dump uses fully-qualified `public.` everywhere anyway,
  # so the protection is redundant here. Drop the statement.
  defp drop_pg18_search_path_reset(stmt) do
    if stmt =~ ~r/^SELECT\s+pg_catalog\.set_config\('search_path'/i,
      do: "",
      else: stmt
  end
end
