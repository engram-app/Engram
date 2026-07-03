defmodule Engram.Repo.Migrations.NotesOkfFieldsExpand do
  use Ecto.Migration

  def change do
    alter table(:notes) do
      add :fm_timestamp, :utc_datetime
      add :fm_created, :utc_datetime
      add :type_ciphertext, :binary
      add :type_nonce, :binary
      add :type_hmac, :binary
      add :description_ciphertext, :binary
      add :description_nonce, :binary
      add :resource_ciphertext, :binary
      add :resource_nonce, :binary
    end

    create index(:notes, [:user_id, :vault_id, :fm_timestamp])
    create index(:notes, [:user_id, :vault_id, :fm_created])
    create index(:notes, [:user_id, :vault_id, :type_hmac])
  end
end
