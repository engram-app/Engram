defmodule Engram.Repo.Migrations.ConvertOauthIpColumnsToText do
  use Ecto.Migration

  # Migrations 20260530000002 / 000003 originally added `first_ip` and
  # `last_used_ip` as `:inet`, then were edited in place to `:text` after the
  # `:inet` versions had already run on prod. Fresh DBs get `:text`; prod DBs
  # still hold `:inet`, which crashes DCR registration with
  # `Postgrex.EncodeError` because the controller now stamps a plain string.
  # Idempotent: only ALTER when the column is still `inet`.

  def up do
    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'oauth_clients'
          AND column_name = 'first_ip'
          AND udt_name = 'inet'
      ) THEN
        ALTER TABLE oauth_clients
          ALTER COLUMN first_ip TYPE text USING first_ip::text;
      END IF;

      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'oauth_refresh_tokens'
          AND column_name = 'last_used_ip'
          AND udt_name = 'inet'
      ) THEN
        ALTER TABLE oauth_refresh_tokens
          ALTER COLUMN last_used_ip TYPE text USING last_used_ip::text;
      END IF;
    END $$;
    """
  end

  def down do
    execute """
    ALTER TABLE oauth_clients
      ALTER COLUMN first_ip TYPE inet USING first_ip::inet
    """

    execute """
    ALTER TABLE oauth_refresh_tokens
      ALTER COLUMN last_used_ip TYPE inet USING last_used_ip::inet
    """
  end
end
