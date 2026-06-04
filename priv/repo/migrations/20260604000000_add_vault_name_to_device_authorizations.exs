defmodule Engram.Repo.Migrations.AddVaultNameToDeviceAuthorizations do
  use Ecto.Migration

  # squawk-ignore-file — `device_authorizations` is short-lived (5-min TTL
  # + cleanup_expired sweep) and uses the repo-wide varchar/string pattern;
  # the prefer-text-field lint doesn't earn its cost here.
  #
  # Plugin sends its local Obsidian vault name when starting the device
  # flow so the `/link` consent page can pre-fill the "create new vault"
  # field. The value lives only as long as the device-authorization row
  # (5-minute TTL + the cleanup_expired sweep), so it stays short-lived
  # and is never persisted past consent.

  def up do
    alter table(:device_authorizations) do
      add :vault_name, :string
    end
  end

  def down do
    alter table(:device_authorizations) do
      remove :vault_name
    end
  end
end
