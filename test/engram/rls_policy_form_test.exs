defmodule Engram.RlsPolicyFormTest do
  @moduledoc """
  Guards the `auth_rls_initplan` advisory: tenant-isolation policies must wrap
  `current_setting('app.current_tenant', ...)` in a scalar subquery so Postgres
  evaluates it once per statement instead of once per row.

  Isolation behaviour itself is covered by RepoTenantTest /
  RepoUserAgreementsTenantTest — this only asserts the optimized policy shape.
  """
  use Engram.DataCase, async: true

  # Derived from the canonical guarded set so this test cannot drift when a
  # tenant table is added (onboarding_actions + crdt_update_log previously
  # escaped the assertion because this list was hardcoded — 2026-07-02 audit).
  @tenant_tables Enum.map(Engram.Repo.tenant_tables(), &Atom.to_string/1)

  # A table whose policy is not named tenant_isolation_<table> makes the
  # query below return no rows and the match fail loudly — align the name.
  test "tenant_isolation policies wrap current_setting in (SELECT ...)" do
    for table <- @tenant_tables do
      %{rows: [[using_expr, check_expr]]} =
        Repo.query!(
          """
          SELECT pg_get_expr(p.polqual, p.polrelid),
                 pg_get_expr(p.polwithcheck, p.polrelid)
          FROM pg_policy p
          JOIN pg_class c ON c.oid = p.polrelid
          WHERE c.relname = $1 AND p.polname = $2
          """,
          [table, "tenant_isolation_#{table}"]
        )

      assert using_expr =~ ~r/\(\s*SELECT current_setting/i,
             "USING clause on #{table} must wrap current_setting in (SELECT ...); got: #{using_expr}"

      assert check_expr =~ ~r/\(\s*SELECT current_setting/i,
             "WITH CHECK clause on #{table} must wrap current_setting in (SELECT ...); got: #{check_expr}"
    end
  end
end
