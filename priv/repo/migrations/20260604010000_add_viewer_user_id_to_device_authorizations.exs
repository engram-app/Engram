defmodule Engram.Repo.Migrations.AddViewerUserIdToDeviceAuthorizations do
  use Ecto.Migration

  # squawk-ignore-file — `device_authorizations` is short-lived (5-min TTL),
  # so the adding-foreign-key + non-concurrent index lints don't earn their
  # cost. FK + index are intentional for the new viewer-binding lookup
  # (atomic UPDATE) and the on_delete: :nilify_all cascade.
  #
  # Binds the suggested_vault_name lookup on /api/vaults?user_code=... to
  # the first authenticated user who reads the code. Without this anyone
  # signed in could probe an observed user_code (shoulder-surfed off the
  # plugin modal, screen-shared, etc.) and read another user's local
  # Obsidian vault name. The row's main `user_id` is set later, at
  # authorize time, and is unsuitable as a pre-authorize ownership check.

  def up do
    alter table(:device_authorizations) do
      add :viewer_user_id, references(:users, type: :uuid, on_delete: :nilify_all)
    end

    # Covering index for the FK — splinter flags unindexed FKs and the
    # `on_delete: :nilify_all` cascade benefits from one too.
    create index(:device_authorizations, [:viewer_user_id])
  end

  def down do
    drop index(:device_authorizations, [:viewer_user_id])

    alter table(:device_authorizations) do
      remove :viewer_user_id
    end
  end
end
