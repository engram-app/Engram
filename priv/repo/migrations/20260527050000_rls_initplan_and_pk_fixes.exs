defmodule Engram.Repo.Migrations.RlsInitplanAndPkFixes do
  use Ecto.Migration

  # Tenant-isolation policies whose `current_setting('app.current_tenant')`
  # call must be wrapped in a scalar subquery so the planner evaluates it once
  # per statement (initplan) instead of once per row. Behaviour is identical;
  # this is purely a query-plan optimization (Supabase advisor: auth_rls_initplan).
  @tenant_tables ~w(notes chunks attachments api_keys vaults user_agreements)

  def up do
    for table <- @tenant_tables do
      execute "DROP POLICY IF EXISTS tenant_isolation_#{table} ON #{table}"

      execute """
      CREATE POLICY tenant_isolation_#{table} ON #{table}
        USING (user_id::text = (SELECT current_setting('app.current_tenant', true)))
        WITH CHECK (user_id::text = (SELECT current_setting('app.current_tenant', true)))
      """
    end

    # client_origin_stats was created with primary_key: false; its composite
    # unique index already enforces the natural key, so promote it in place to
    # the primary key (no rebuild) rather than adding a surrogate column.
    execute """
    ALTER TABLE client_origin_stats
      ADD PRIMARY KEY USING INDEX client_origin_stats_user_id_day_fingerprint_class_index
    """
  end

  def down do
    for table <- @tenant_tables do
      execute "DROP POLICY IF EXISTS tenant_isolation_#{table} ON #{table}"

      execute """
      CREATE POLICY tenant_isolation_#{table} ON #{table}
        USING (user_id::text = current_setting('app.current_tenant', true))
        WITH CHECK (user_id::text = current_setting('app.current_tenant', true))
      """
    end

    execute "ALTER TABLE client_origin_stats DROP CONSTRAINT client_origin_stats_pkey"

    execute """
    CREATE UNIQUE INDEX client_origin_stats_user_id_day_fingerprint_class_index
      ON client_origin_stats (user_id, day, fingerprint_class)
    """
  end
end
