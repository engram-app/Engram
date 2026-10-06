defmodule Engram.Repo.Migrations.RevokeAppWritesSchemaMigrationsExpand do
  use Ecto.Migration

  # phase/expand — `engram_app` must not write `schema_migrations`. Forward-
  # compatible: no release of the app writes it as `engram_app`.
  #
  # The table inherits the migrator's default ACL (SELECT/INSERT/UPDATE/DELETE
  # to `engram_app`, `Engram.Release`), but only the migrator ever writes it.
  # With writes granted, a compromised app credential can DELETE a version row
  # so the next deploy re-runs that migration as the privileged migrator (e.g.
  # `clear_crdt_state_id_keying_cutover_migrate` wipes every tenant's CRDT
  # state), or INSERT a future version so a security migration never runs.
  #
  # SELECT stays: `Engram.Release.Preflight` reads it as the app role.
  # Guarded on the role, as in #1766. Pinned by `Engram.Repo.AppRolePrivilegesTest`.

  def up do
    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'engram_app') THEN
        REVOKE INSERT, UPDATE, DELETE ON public.schema_migrations FROM engram_app;
      END IF;
    END
    $$;
    """
  end

  def down do
    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'engram_app') THEN
        GRANT INSERT, UPDATE, DELETE ON public.schema_migrations TO engram_app;
      END IF;
    END
    $$;
    """
  end
end
