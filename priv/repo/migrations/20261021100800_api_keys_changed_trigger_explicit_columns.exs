defmodule Engram.Repo.Migrations.ApiKeysChangedTriggerExplicitColumns do
  use Ecto.Migration

  # Authentication now stamps api_keys.last_used (hourly per key). The
  # api_keys_changed UPDATE trigger (20261009120001) already skipped
  # last_used-only updates, by building to_jsonb(OLD) and to_jsonb(NEW); it
  # now compares every other column as two row values. CacheEvictionTriggersTest
  # fails when a new column is missing from the list (a column dropped later
  # must come out of it in its drop migration). lock_timeout as in
  # 20261021100600.
  @cols ~w(id user_id key_hash name created_at default_access)

  def up do
    old = Enum.map_join(@cols, ", ", &"OLD.#{&1}")
    new = Enum.map_join(@cols, ", ", &"NEW.#{&1}")
    replace("ROW(#{old}) IS DISTINCT FROM ROW(#{new})")
  end

  def down,
    do: replace("(to_jsonb(OLD) - 'last_used') IS DISTINCT FROM (to_jsonb(NEW) - 'last_used')")

  defp replace(when_clause) do
    execute "SET LOCAL lock_timeout = '5s'"

    execute """
    CREATE OR REPLACE TRIGGER api_keys_cache_notify_1
    AFTER UPDATE ON api_keys
    FOR EACH ROW WHEN (#{when_clause})
    EXECUTE FUNCTION notify_api_keys_changed();
    """
  end
end
