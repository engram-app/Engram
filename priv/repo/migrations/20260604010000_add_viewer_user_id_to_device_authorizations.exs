defmodule Engram.Repo.Migrations.AddViewerUserIdToDeviceAuthorizations do
  use Ecto.Migration

  # Binds the suggested_vault_name lookup on /api/vaults?user_code=... to
  # the first authenticated user who reads the code. Without this anyone
  # signed in could probe an observed user_code (shoulder-surfed off the
  # plugin modal, screen-shared, etc.) and read another user's local
  # Obsidian vault name. The row's main `user_id` is set later, at
  # authorize time, and is unsuitable as a pre-authorize ownership check.

  def up do
    alter table(:device_authorizations) do
      add :viewer_user_id, references(:users, on_delete: :nilify_all)
    end
  end

  def down do
    alter table(:device_authorizations) do
      remove :viewer_user_id
    end
  end
end
