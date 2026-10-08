defmodule Engram.Repo.Migrations.ScopeApiKeysDiscoveryToKeyLookupContract do
  use Ecto.Migration

  # phase/contract — #1867, step 2 of 2. Scopes `api_keys_discovery` TO
  # `engram_key_lookup`.
  #
  # WHY. The policy is `FOR SELECT USING (no tenant set)` and had no TO clause,
  # so it applied to every role: ANY unscoped query as engram_app (e.g. a join
  # from users) returned every user's key_hash/name/user_id. Only
  # `Accounts.validate_api_key/1` legitimately needs the tenant-less read, and
  # since the previous release it runs that read under
  # `SET LOCAL ROLE engram_key_lookup`. engram_app holds that role WITHOUT
  # INHERIT, so policies scoped TO it do not apply to plain engram_app.
  #
  # ORDERING. Must ship in a release AFTER the one that taught
  # validate_api_key/1 to switch roles (migration 20261006160000). N-1 code
  # reads as plain engram_app and would 401 every API-key request once this
  # applies, including during the rolling deploy window.
  #
  # The role is created here if missing so ALTER POLICY ... TO cannot fail with
  # 42704 on a database whose `prepare_database` predates it. Every boot path
  # runs `prepare_database` before migrate, which grants engram_app membership.

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

    execute "ALTER POLICY api_keys_discovery ON api_keys TO engram_key_lookup"
  end

  # Restores the pre-#1867 shape (applies to every role), which N-1 code needs.
  def down do
    execute "ALTER POLICY api_keys_discovery ON api_keys TO PUBLIC"
  end
end
