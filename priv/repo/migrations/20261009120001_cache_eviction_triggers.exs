defmodule Engram.Repo.Migrations.CacheEvictionTriggers do
  use Ecto.Migration

  @moduledoc """
  pg_notify on writes to the tables behind Engram.Cache (users, subscriptions,
  api_keys, api_key_vaults, vaults) so every node evicts immediately, for EVERY
  writer including raw SQL. Same pattern as notify_on_user_limit_override_change.
  phase/expand: purely additive.

  Channels / payloads (text):
    users_changed          users.id                (UPDATE, DELETE)
    subscriptions_changed  subscriptions.user_id   (INSERT, UPDATE, DELETE)
    api_keys_changed       api_keys.key_hash       (UPDATE except last_used-only, DELETE)
    api_key_vaults_changed api_key_vaults.api_key_id (INSERT, UPDATE, DELETE)
    vaults_changed         vaults.user_id          (INSERT, DELETE, UPDATE except
                                                    change_seq/updated_at-only; every
                                                    note write bumps change_seq)
  """

  # {table, channel, payload expression, extra trigger clauses}
  @triggers [
    {"users", "users_changed", "OLD.id", [{"AFTER UPDATE OR DELETE", nil}]},
    {"subscriptions", "subscriptions_changed", "COALESCE(NEW.user_id, OLD.user_id)",
     [{"AFTER INSERT OR UPDATE OR DELETE", nil}]},
    {"api_keys", "api_keys_changed", "OLD.key_hash",
     [
       {"AFTER DELETE", nil},
       {"AFTER UPDATE",
        "(to_jsonb(OLD) - 'last_used') IS DISTINCT FROM (to_jsonb(NEW) - 'last_used')"}
     ]},
    {"api_key_vaults", "api_key_vaults_changed", "COALESCE(NEW.api_key_id, OLD.api_key_id)",
     [{"AFTER INSERT OR UPDATE OR DELETE", nil}]},
    {"vaults", "vaults_changed", "COALESCE(NEW.user_id, OLD.user_id)",
     [
       {"AFTER INSERT OR DELETE", nil},
       {"AFTER UPDATE",
        "(to_jsonb(OLD) - 'change_seq' - 'updated_at') IS DISTINCT FROM (to_jsonb(NEW) - 'change_seq' - 'updated_at')"}
     ]}
  ]

  def up do
    for {table, channel, payload, triggers} <- @triggers do
      execute("""
      CREATE OR REPLACE FUNCTION notify_#{channel}() RETURNS trigger AS $$
      BEGIN
        PERFORM pg_notify('#{channel}', (#{payload})::text);
        RETURN COALESCE(NEW, OLD);
      END;
      $$ LANGUAGE plpgsql
      -- Pinned search_path (splinter: function_search_path_mutable); the body
      -- only touches pg_catalog builtins.
      SET search_path = '';
      """)

      for {{event, when_clause}, i} <- Enum.with_index(triggers) do
        when_sql = if when_clause, do: "WHEN (#{when_clause})", else: ""

        execute("""
        CREATE OR REPLACE TRIGGER #{table}_cache_notify_#{i}
        #{event} ON #{table}
        FOR EACH ROW #{when_sql}
        EXECUTE FUNCTION notify_#{channel}();
        """)
      end
    end
  end

  def down do
    for {table, channel, _payload, triggers} <- @triggers do
      for {_, i} <- Enum.with_index(triggers),
          do: execute("DROP TRIGGER IF EXISTS #{table}_cache_notify_#{i} ON #{table};")

      execute("DROP FUNCTION IF EXISTS notify_#{channel}();")
    end
  end
end
