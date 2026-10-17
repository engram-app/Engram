defmodule Engram.Repo.Migrations.NotifyOnOAuthGrantChange do
  use Ecto.Migration

  @moduledoc """
  pg_notify on `oauth_refresh_tokens` writes that change what a grant may do,
  so every node evicts its `:oauth_grant` cache entry (`Engram.Cache.Registry`)
  immediately, for EVERY writer including raw SQL. Same pattern as
  `20261009120001_cache_eviction_triggers`. phase/expand: purely additive.

  Channel `oauth_refresh_tokens_changed`, payload `family_id` (text):
    * UPDATE of `revoked_at`, `vault_access`, `default_access` or `vault_ids`
      (a revoke, or vault deletion narrowing a pre-levels grant). Rotation
      only sets `consumed_at` / `last_used_*` and does not fire.
    * DELETE (cleanup of expired or long-revoked rows).
  INSERT does not fire: a rotation successor carries its family's levels
  unchanged.
  """

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION notify_oauth_refresh_tokens_changed() RETURNS trigger AS $$
    BEGIN
      PERFORM pg_notify('oauth_refresh_tokens_changed', (COALESCE(NEW.family_id, OLD.family_id))::text);
      RETURN COALESCE(NEW, OLD);
    END;
    $$ LANGUAGE plpgsql
    -- Pinned search_path (splinter: function_search_path_mutable); the body
    -- only touches pg_catalog builtins.
    SET search_path = '';
    """)

    execute("""
    CREATE OR REPLACE TRIGGER oauth_refresh_tokens_cache_notify_0
    AFTER DELETE ON oauth_refresh_tokens
    FOR EACH ROW EXECUTE FUNCTION notify_oauth_refresh_tokens_changed();
    """)

    execute("""
    CREATE OR REPLACE TRIGGER oauth_refresh_tokens_cache_notify_1
    AFTER UPDATE ON oauth_refresh_tokens
    FOR EACH ROW WHEN (
      OLD.revoked_at IS DISTINCT FROM NEW.revoked_at
      OR OLD.vault_access IS DISTINCT FROM NEW.vault_access
      OR OLD.default_access IS DISTINCT FROM NEW.default_access
      OR OLD.vault_ids IS DISTINCT FROM NEW.vault_ids
    )
    EXECUTE FUNCTION notify_oauth_refresh_tokens_changed();
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS oauth_refresh_tokens_cache_notify_1 ON oauth_refresh_tokens;")
    execute("DROP TRIGGER IF EXISTS oauth_refresh_tokens_cache_notify_0 ON oauth_refresh_tokens;")
    execute("DROP FUNCTION IF EXISTS notify_oauth_refresh_tokens_changed();")
  end
end
