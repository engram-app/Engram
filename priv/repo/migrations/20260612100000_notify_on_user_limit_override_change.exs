defmodule Engram.Repo.Migrations.NotifyOnUserLimitOverrideChange do
  use Ecto.Migration

  @moduledoc """
  pg_notify on every user_limit_overrides write so the per-node
  OverrideCache (60s TTL) evicts immediately — for EVERY writer,
  including raw SQL (support-runbook grants, e2e helpers) that can't
  call the app's eviction API. phase/expand: purely additive.
  """

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION notify_user_limit_override_change() RETURNS trigger AS $$
    BEGIN
      PERFORM pg_notify(
        'user_limit_overrides_changed',
        (COALESCE(NEW.user_id, OLD.user_id))::text
      );
      RETURN COALESCE(NEW, OLD);
    END;
    $$ LANGUAGE plpgsql
    -- Pinned search_path (splinter: function_search_path_mutable). The body
    -- only touches pg_catalog builtins, so empty is correct.
    SET search_path = '';
    """)

    execute("""
    CREATE TRIGGER user_limit_overrides_notify
    AFTER INSERT OR UPDATE OR DELETE ON user_limit_overrides
    FOR EACH ROW EXECUTE FUNCTION notify_user_limit_override_change();
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS user_limit_overrides_notify ON user_limit_overrides;")
    execute("DROP FUNCTION IF EXISTS notify_user_limit_override_change();")
  end
end
