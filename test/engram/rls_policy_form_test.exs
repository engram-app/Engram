defmodule Engram.RlsPolicyFormTest do
  @moduledoc """
  Guards the `auth_rls_initplan` advisory: tenant-isolation policies must wrap
  `current_setting('app.current_tenant', ...)` in a scalar subquery so Postgres
  evaluates it once per statement instead of once per row.

  Isolation behaviour itself is covered by RepoTenantTest /
  RepoUserAgreementsTenantTest — this only asserts the optimized policy shape.
  """
  use Engram.DataCase, async: true

  @tenant_tables ~w(notes chunks attachments api_keys vaults user_agreements)

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
