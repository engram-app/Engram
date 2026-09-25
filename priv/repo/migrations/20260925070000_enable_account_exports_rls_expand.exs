defmodule Engram.Repo.Migrations.EnableAccountExportsRlsExpand do
  use Ecto.Migration

  # squawk-ignore-file
  #
  # phase/expand — engram-app/Engram#1758. Brings `account_exports` under the
  # same tenant policy as the other per-user tables. It holds pointers to
  # complete archives of a user's personal data, and until now it was scoped by
  # an app-side `user_id` filter alone.
  #
  # The code that ships with this migration names the tenant on every access
  # (`with_tenant/2`, or `Repo.maintenance()` for the expiry sweep). One
  # consequence is deliberate: where RLS is enforced and no maintenance pool is
  # configured (SaaS prod at the time of writing), `ExportExpirySweep` refuses
  # with `:tenancy_unsafe` rather than expire nothing, and `mint_download_url/2`
  # enforces `expires_at` itself so the download window holds meanwhile. Prod
  # held 0 rows when this landed, so the rolling-deploy window, where old nodes
  # still run unscoped queries, has nothing to filter.
  #
  # Policy form matches every other tenant table; `Engram.RlsPolicyFormTest`
  # pins the `(SELECT current_setting(...))` wrapper.
  def change do
    execute(
      "ALTER TABLE account_exports ENABLE ROW LEVEL SECURITY",
      "ALTER TABLE account_exports DISABLE ROW LEVEL SECURITY"
    )

    execute(
      "ALTER TABLE account_exports FORCE ROW LEVEL SECURITY",
      "ALTER TABLE account_exports NO FORCE ROW LEVEL SECURITY"
    )

    execute(
      """
      CREATE POLICY tenant_isolation_account_exports ON account_exports
        USING (user_id::text = (SELECT current_setting('app.current_tenant', true)))
        WITH CHECK (user_id::text = (SELECT current_setting('app.current_tenant', true)))
      """,
      "DROP POLICY IF EXISTS tenant_isolation_account_exports ON account_exports"
    )
  end
end
