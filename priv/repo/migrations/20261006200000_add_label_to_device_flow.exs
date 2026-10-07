defmodule Engram.Repo.Migrations.AddLabelToDeviceFlow do
  use Ecto.Migration

  # Three nullable text columns, no backfill, no index. `if_not_exists` keeps a
  # rerun harmless where an earlier build of this change already added them.
  #
  # The Obsidian link page now lets the user name the connection, as the OAuth
  # consent screen already does (`oauth_refresh_tokens.label`). The label is
  # typed before the device code is exchanged, so it rides on
  # `device_authorizations` and is copied onto the `device_refresh_tokens`
  # family (and every rotation of it), where the connections list reads it.
  #
  # NULL means "no label chosen": existing rows and unlabeled links keep
  # showing the client name.
  def change do
    alter table(:device_authorizations) do
      add_if_not_exists :label, :text
      # Name the plugin suggests for itself at flow start (hostname, platform),
      # shown on /link as the default label. Lives as long as the pending row.
      add_if_not_exists :device_name, :text
    end

    alter table(:device_refresh_tokens) do
      add_if_not_exists :label, :text
    end
  end
end
