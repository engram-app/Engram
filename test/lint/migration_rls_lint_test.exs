defmodule Engram.MigrationRlsLintTest do
  @moduledoc """
  Grep-style lint: raw DML in a migration must NOT target a tenant-scoped
  table without explicitly handling FORCE ROW LEVEL SECURITY.

  Migrations run as the migrator role — `engram_admin` (RDS master) on prod,
  which is the table owner but has neither SUPERUSER nor BYPASSRLS. Tenant
  tables carry FORCE ROW LEVEL SECURITY, and a migration sets no
  `app.current_tenant`, so the tenant policy sees NULL and filters every row:
  the DML "succeeds" touching 0 rows — a silent no-op. Dev/CI mask the bug
  because their Docker `POSTGRES_USER` is a superuser, which bypasses RLS
  regardless of FORCE, so the migration works there and CI stays green.

  The accepted pattern is to drop the owner-applies flag for the migration
  transaction and restore it before commit:

      execute("ALTER TABLE notes NO FORCE ROW LEVEL SECURITY")
      execute("UPDATE notes SET ...")
      execute("ALTER TABLE notes FORCE ROW LEVEL SECURITY")

  (Owner bypasses RLS unless FORCE, so NO FORCE restores the bypass; the
  ACCESS EXCLUSIVE lock keeps app queries out of the unforced window, and a
  rollback restores FORCE.) A migration that does this — or is allowlisted
  with a justification — passes the lint.

  Tenant tables are sourced from `Engram.Repo.tenant_tables/0` so the lint
  can't drift from the guarded set. Sibling of
  `Engram.RawSqlTenantTableLintTest`, which covers `lib/` but not
  `priv/repo/migrations/`.
  """
  use ExUnit.Case, async: true

  @migrations_dir Path.expand("../../priv/repo/migrations", __DIR__)

  @tenant_tables Enum.map(Engram.Repo.tenant_tables(), &Atom.to_string/1)

  # Migrations allowed to run tenant-table DML without the NO FORCE dance.
  # Each entry needs a comment explaining why (e.g. predates FORCE RLS and is
  # already applied in every environment).
  @allowlist []

  test "tenant-table DML in migrations handles FORCE ROW LEVEL SECURITY" do
    offenders =
      @migrations_dir
      |> Path.join("*.exs")
      |> Path.wildcard()
      |> Enum.reject(fn path ->
        Enum.any?(@allowlist, &String.ends_with?(path, &1))
      end)
      |> Enum.flat_map(&scan_file/1)

    assert offenders == [],
           "Tenant-table DML in a migration runs RLS-filtered to ZERO rows on " <>
             "prod (FORCE RLS + no tenant context = silent no-op; dev/CI " <>
             "superuser masks it). Wrap the DML in " <>
             "ALTER TABLE <t> NO FORCE ROW LEVEL SECURITY / FORCE ROW LEVEL " <>
             "SECURITY, or allowlist the file with a justification.\n\n" <>
             Enum.map_join(offenders, "\n", fn {file, table} ->
               "#{file} → table `#{table}`"
             end)
  end

  defp scan_file(path) do
    content = File.read!(path)
    rel = Path.relative_to(path, @migrations_dir)

    Enum.flat_map(@tenant_tables, fn table ->
      dml = ~r/\b(?:UPDATE|DELETE\s+FROM|INSERT\s+INTO)\s+#{table}\b/i
      unforce = ~r/ALTER\s+TABLE\s+#{table}\s+NO\s+FORCE\s+ROW\s+LEVEL\s+SECURITY/i
      reforce = ~r/ALTER\s+TABLE\s+#{table}\s+FORCE\s+ROW\s+LEVEL\s+SECURITY/i

      if Regex.match?(dml, content) and
           not (Regex.match?(unforce, content) and Regex.match?(reforce, content)) do
        [{rel, table}]
      else
        []
      end
    end)
  end
end
