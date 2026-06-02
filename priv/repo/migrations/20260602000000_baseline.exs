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

  The `engram_app` runtime role (used by `Repo.with_tenant/2` to enforce RLS)
  is created here idempotently. In dev/CI the role survives `mix ecto.drop`
  (cluster-level), but a fresh CI postgres container has no roles and needs
  this step to succeed before the dumped GRANT statements can reference it.
  """

  use Ecto.Migration

  @engram_app_role_sql """
  DO $$
  BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'engram_app') THEN
      CREATE ROLE engram_app NOINHERIT LOGIN PASSWORD 'engram_app';
    END IF;
  END
  $$;
  """

  def up do
    repo().query!(@engram_app_role_sql, [], log: false)

    path = Path.join(:code.priv_dir(:engram), "repo/structure.sql")

    path
    |> File.read!()
    |> split_statements()
    |> Enum.each(fn stmt -> repo().query!(stmt, [], log: false) end)
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
    |> Enum.reject(&String.starts_with?(String.trim(&1), "--"))
    |> Enum.join("\n")
    |> String.trim()
  end
end
