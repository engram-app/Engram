defmodule Engram.Repo.Migrations.AddEngramKeyLookupRoleExpand do
  use Ecto.Migration

  # phase/expand — #1867, step 1 of 2. Gives `engram_key_lookup` (the role
  # `Accounts.validate_api_key/1` switches to for its tenant-less key_hash
  # lookup) SELECT on api_keys. Additive: `api_keys_discovery` still applies
  # to every role, so N-1 code keeps authenticating. The follow-up contract
  # migration scopes the policy TO this role once no N-1 task is serving.
  #
  # The role is created here if missing because the n1-compat gate runs the
  # previous tag's `prepare_database`, which predates it. `prepare_database`
  # owns the role (and engram_app's membership); this only adds the grant,
  # which cannot live there because on a fresh database it runs before
  # api_keys exists.

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

    execute "GRANT SELECT ON public.api_keys TO engram_key_lookup"
  end

  def down do
    execute "REVOKE SELECT ON public.api_keys FROM engram_key_lookup"
  end
end
