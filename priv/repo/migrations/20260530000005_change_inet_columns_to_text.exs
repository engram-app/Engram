defmodule Engram.Repo.Migrations.ChangeInetColumnsToText do
  use Ecto.Migration

  def up do
    execute "ALTER TABLE oauth_clients ALTER COLUMN first_ip TYPE text USING first_ip::text"

    execute "ALTER TABLE oauth_refresh_tokens ALTER COLUMN last_used_ip TYPE text USING last_used_ip::text"
  end

  def down do
    execute "ALTER TABLE oauth_clients ALTER COLUMN first_ip TYPE inet USING first_ip::inet"

    execute "ALTER TABLE oauth_refresh_tokens ALTER COLUMN last_used_ip TYPE inet USING last_used_ip::inet"
  end
end
