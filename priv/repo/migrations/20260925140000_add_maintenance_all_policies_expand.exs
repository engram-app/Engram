defmodule Engram.Repo.Migrations.AddMaintenanceAllPoliciesExpand do
  use Ecto.Migration

  # squawk-ignore-file
  #
  # phase/expand — adds one permissive policy per tenant table. Additive: no
  # existing role gains or loses anything, because each policy applies only
  # `TO engram_maintenance`, a role nothing connects as until infra sets
  # MAINTENANCE_DATABASE_URL to it.
  #
  # WHY. `Engram.Repo.Maintenance` is the pool for work that legitimately spans
  # tenants (OrphanSweep, CrdtBloatSweep, ExportExpirySweep, CleanupVault). Under
  # FORCE RLS it needs a credential the tenant policy does not filter. Prod has
  # been using the RDS master (`engram_admin`) for that, which also carries
  # CREATEROLE, DDL and schema ownership — far more than a sweep needs.
  #
  # The obvious least-privilege answer, a dedicated BYPASSRLS role, is not
  # available on RDS: the master is CREATEROLE but not superuser, and PG16+
  # only lets a CREATEROLE role grant an attribute it holds itself. So the
  # reach is expressed as policy instead. Permissive policies OR together, so
  # for `engram_maintenance` these make every row visible and writable; for
  # every other role the `TO` clause means they do not exist.
  #
  # The role itself is created by `Engram.Release.prepare_database/0`, which
  # every migrate path runs first. On a database where it was skipped, this
  # fails with `role "engram_maintenance" does not exist`, which is the right
  # outcome — the same contract the baseline already has with engram_app.
  #
  # Kept as a literal list rather than `Engram.Repo.tenant_tables/0`: a
  # migration must describe the schema at ITS point in history, not whatever
  # the module says when it is next run. A new tenant table adds its own
  # `maintenance_all` in its own migration; `Engram.Repo.MaintenanceRoleTest`
  # fails until it does.
  #
  # Per-table this is `CREATE POLICY`, which takes a brief ACCESS EXCLUSIVE
  # lock. Metadata-only, no scan or rewrite.
  @tables ~w(notes chunks attachments api_keys vaults user_agreements onboarding_actions
             crdt_update_log note_links vault_index_states vault_index_update_log)

  def up do
    for t <- @tables do
      execute "CREATE POLICY maintenance_all ON #{t} TO engram_maintenance USING (true) WITH CHECK (true)"
    end
  end

  def down do
    for t <- @tables do
      execute "DROP POLICY IF EXISTS maintenance_all ON #{t}"
    end
  end
end
