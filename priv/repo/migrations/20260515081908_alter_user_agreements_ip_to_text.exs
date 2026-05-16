defmodule Engram.Repo.Migrations.AlterUserAgreementsIpToText do
  use Ecto.Migration

  def up do
    execute "ALTER TABLE user_agreements ALTER COLUMN ip_address TYPE text USING ip_address::text"
  end

  def down do
    execute "ALTER TABLE user_agreements ALTER COLUMN ip_address TYPE inet USING ip_address::inet"
  end
end
