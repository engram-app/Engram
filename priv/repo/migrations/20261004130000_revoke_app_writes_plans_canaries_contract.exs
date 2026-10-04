defmodule Engram.Repo.Migrations.RevokeAppWritesPlansCanariesContract do
  use Ecto.Migration

  # phase/contract — drop write privileges `engram_app` never uses (#1766).
  #
  # `plans` has no runtime writer (`Engram.Billing.PlanCache` only reads it);
  # rows change via the migrator or the maintenance pool. `system_canaries`
  # is written once by `Engram.Crypto.BootCanary.provision!/1` (INSERT) and
  # otherwise only read. Leaving the rest granted lets a compromised app
  # credential rewrite every user's limits or corrupt the boot canary.
  #
  # Guarded on the role: deployments that never ran
  # `Engram.Release.prepare_database/0` have no `engram_app` to revoke from.
  # Pinned by `Engram.Repo.AppRolePrivilegesTest`.

  def up do
    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'engram_app') THEN
        REVOKE INSERT, UPDATE, DELETE ON public.plans FROM engram_app;
        REVOKE UPDATE, DELETE ON public.system_canaries FROM engram_app;
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
        GRANT INSERT, UPDATE, DELETE ON public.plans TO engram_app;
        GRANT UPDATE, DELETE ON public.system_canaries TO engram_app;
      END IF;
    END
    $$;
    """
  end
end
