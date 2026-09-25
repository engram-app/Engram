defmodule Engram.Repo.Migrations.AddMaintenanceAllPoliciesExpand do
  use Ecto.Migration

  # squawk-ignore-file
  #
  # phase/expand: adds one permissive policy per tenant table. Additive: no
  # existing role gains or loses anything, because each policy applies only
  # `TO engram_maintenance`, a role nothing connects as until infra sets
  # MAINTENANCE_DATABASE_URL to it.
  #
  # WHY. `Engram.Repo.Maintenance` is the pool for work that legitimately spans
  # tenants (OrphanSweep, CrdtBloatSweep, ExportExpirySweep, CleanupVault). Under
  # FORCE RLS it needs a credential the tenant policy does not filter. Prod has
  # been using the RDS master (`engram_admin`) for that, which also carries
  # CREATEROLE, DDL and schema ownership, far more than a sweep needs.
  #
  # The obvious least-privilege answer, a dedicated BYPASSRLS role, is not
  # available on RDS: the master is CREATEROLE but not superuser, and PG16+
  # only lets a CREATEROLE role grant an attribute it holds itself. So the
  # reach is expressed as policy instead. Permissive policies OR together, so
  # for `engram_maintenance` these make every row visible and writable; for
  # every other role the `TO` clause means they do not exist.
  #
  # The role is OWNED by `Engram.Release.prepare_database/0` (attributes,
  # grants, password). This migration still creates it if missing, because a
  # migration must apply on top of the PREVIOUS release's bootstrap: the
  # n1-compat gate (and any env migrated before its image's prepare_database
  # ran) has no `engram_maintenance`, and `CREATE POLICY ... TO` an unknown
  # role fails with 42704. Same guarded statement, same attributes
  # (NOINHERIT LOGIN, nothing else), so the two are idempotent in either
  # order. The migrator can do it: `engram_admin` has CREATEROLE on RDS, and
  # dev/CI/FastRaid migrate as a superuser.
  #
  # A role created here has no grants and no password, so it can neither log
  # in nor read anything until prepare_database runs. `down/0` leaves the
  # role: prepare_database owns it, and dropping it would break a
  # rollback-then-reapply (and fail outright once its grants exist).
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
             crdt_update_log note_links vault_index_states vault_index_update_log
             account_exports)

  def up do
    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'engram_maintenance') THEN
        CREATE ROLE engram_maintenance NOINHERIT LOGIN;
      END IF;
    END
    $$;
    """

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
