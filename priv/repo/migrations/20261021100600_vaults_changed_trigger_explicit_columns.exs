defmodule Engram.Repo.Migrations.VaultsChangedTriggerExplicitColumns do
  use Ecto.Migration

  # The vaults_changed UPDATE trigger (20261009120001) decided "anything but
  # change_seq/updated_at changed" by building to_jsonb(OLD) and
  # to_jsonb(NEW), on every UPDATE of vaults, and the seq bump of every note
  # write is one. Same decision, comparing the columns as two row values.
  # Every vaults column but those two is listed; CacheEvictionTriggersTest
  # fails when a new column is missing from it (a column dropped later must
  # come out of this list in its drop migration: Postgres refuses to drop a
  # column a trigger names).
  #
  # CREATE OR REPLACE TRIGGER locks vaults briefly; lock_timeout makes a busy
  # table fail the migration (retried on the next boot) instead of queueing
  # every writer behind it.
  @cols ~w(id user_id description slug client_id is_default deleted_at created_at
           name_ciphertext name_nonce name_hmac dek_version slug_hmac slug_suffixed
           purge_started_at)

  def up do
    old = Enum.map_join(@cols, ", ", &"OLD.#{&1}")
    new = Enum.map_join(@cols, ", ", &"NEW.#{&1}")
    replace("ROW(#{old}) IS DISTINCT FROM ROW(#{new})")
  end

  def down do
    replace(
      "(to_jsonb(OLD) - 'change_seq' - 'updated_at') IS DISTINCT FROM " <>
        "(to_jsonb(NEW) - 'change_seq' - 'updated_at')"
    )
  end

  defp replace(when_clause) do
    execute "SET LOCAL lock_timeout = '5s'"

    execute """
    CREATE OR REPLACE TRIGGER vaults_cache_notify_1
    AFTER UPDATE ON vaults
    FOR EACH ROW WHEN (#{when_clause})
    EXECUTE FUNCTION notify_vaults_changed();
    """
  end
end
