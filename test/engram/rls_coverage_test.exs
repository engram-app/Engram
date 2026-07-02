defmodule Engram.RlsCoverageTest do
  @moduledoc """
  Guards multi-tenant isolation at the schema level: every table with a
  `user_id` column must either enforce a row-level-security policy or be
  explicitly listed as relying on application-layer scoping. Adding a new
  user-scoped table forces that decision instead of silently shipping a table
  with no database-level tenant backstop.
  """
  use Engram.DataCase, async: true

  # User-scoped tables that deliberately rely on application-layer `user_id`
  # filtering rather than a database RLS policy. Adding an entry here is a
  # conscious decision — prefer enabling RLS for anything holding tenant data.
  # idempotency_keys: reads/writes always filter user_id app-side, the payload
  # is DEK-encrypted + AAD-bound to (user_id, key) — cryptographic tenant
  # isolation even on a scoping bug — and the daily prune worker needs cheap
  # cross-tenant deletes (FORCE RLS would block the app-role sweep).
  @no_rls_allowlist ~w(
    account_exports
    client_logs
    idempotency_keys
    client_origin_stats
    device_authorizations
    device_refresh_tokens
    oauth_authorization_codes
    oauth_refresh_tokens
    password_reset_tokens
    refresh_tokens
    subscriptions
    usage_buckets
    usage_meters
    user_limit_overrides
  )

  defp user_scoped_tables do
    %{rows: rows} =
      Repo.query!("""
      SELECT c.relname, c.relrowsecurity, c.relforcerowsecurity,
             (SELECT count(*) FROM pg_policy p WHERE p.polrelid = c.oid)
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relkind = 'r'
        AND EXISTS (
          SELECT 1 FROM pg_attribute a
          WHERE a.attrelid = c.oid AND a.attname = 'user_id' AND NOT a.attisdropped
        )
      """)

    rows
  end

  test "every user-scoped table has an RLS policy or is explicitly allowlisted" do
    # A table is protected only if RLS is both ENABLED and FORCED (the table
    # owner / migration role bypasses non-forced RLS) and at least one policy
    # exists.
    unprotected =
      for [table, rls_enabled, rls_forced, policy_count] <- user_scoped_tables(),
          not (rls_enabled and rls_forced and policy_count > 0),
          table not in @no_rls_allowlist,
          do: table

    assert unprotected == [],
           """
           User-scoped tables without FORCEd RLS + a policy, and not allowlisted: \
           #{Enum.join(unprotected, ", ")}.
           Either enable RLS (ENABLE + FORCE ROW LEVEL SECURITY + a tenant_isolation
           policy), or, if application-layer scoping is intentional, add the table to
           @no_rls_allowlist in this test.
           """
  end

  test "no stale allowlist entries (each still exists and lacks RLS)" do
    no_rls_tables =
      for [table, rls_enabled, _rls_forced, _policy_count] <- user_scoped_tables(),
          not rls_enabled,
          do: table

    stale = @no_rls_allowlist -- no_rls_tables

    assert stale == [],
           "Stale @no_rls_allowlist entries (now RLS-protected or removed): #{Enum.join(stale, ", ")}"
  end
end
