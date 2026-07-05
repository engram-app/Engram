defmodule Engram.Repo.Migrations.NotesOkfFieldsExpand do
  use Ecto.Migration

  # phase/expand — OKF v0.1 frontmatter columns (spec 2026-07-02).
  #
  # The two dates are the ONLY plaintext frontmatter columns (range queries
  # need real values); they are :timestamptz per squawk prefer-timestamp-tz
  # (absolute instants; the Ecto schema reads them back as UTC DateTimes).
  # type is encrypted with a type_hmac blind index; description/resource are
  # encrypted display-only.
  #
  # Indexes are created concurrently (squawk require-concurrent-index-creation),
  # which requires running outside the DDL transaction.

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    alter table(:notes) do
      add :fm_timestamp, :timestamptz
      add :fm_created, :timestamptz
      add :type_ciphertext, :binary
      add :type_nonce, :binary
      add :type_hmac, :binary
      add :description_ciphertext, :binary
      add :description_nonce, :binary
      add :resource_ciphertext, :binary
      add :resource_nonce, :binary
    end

    create index(:notes, [:user_id, :vault_id, :fm_timestamp], concurrently: true)
    create index(:notes, [:user_id, :vault_id, :fm_created], concurrently: true)
    create index(:notes, [:user_id, :vault_id, :type_hmac], concurrently: true)
  end
end
