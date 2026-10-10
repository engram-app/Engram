defmodule Engram.Repo.Migrations.GrantKeyLookupApiKeyVaults do
  use Ecto.Migration

  # phase/expand. `Accounts.validate_api_key/1` now reads a key and its vault
  # scope in ONE statement as `engram_key_lookup`, so a CleanupVault that
  # commits between two reads can no longer yield the key with `:all` scope.
  # api_key_vaults has no RLS and holds only (api_key_id, vault_id) pairs.
  # Additive: N-1 code reads the scope as the session role and ignores it.

  def up do
    execute """
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'engram_key_lookup') THEN
        CREATE ROLE engram_key_lookup NOLOGIN;
      END IF;
    END
    $$;
    """

    execute "GRANT SELECT ON public.api_key_vaults TO engram_key_lookup"
  end

  def down do
    execute "REVOKE SELECT ON public.api_key_vaults FROM engram_key_lookup"
  end
end
