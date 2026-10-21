defmodule Engram.Repo.Migrations.IndexStorageObjectsKeyPattern do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # Self-host keeps attachment bytes in storage_objects (Storage.Database).
  # Its prefix delete (a user's or vault's attachments) could not use the
  # primary key under a non-C collation, so it read every row of a table full
  # of file bytes. text_pattern_ops orders byte-wise, which serves the
  # delete's `~>=~`/`~<~` prefix range. Empty on SaaS (S3).
  # Storage.DatabaseTest pins the plan.
  def up do
    # A CONCURRENTLY build that fails (lock timeout, deploy kill) leaves an
    # INVALID index under its name, which a retry would skip or trip on.
    # Dropping the name first makes the retry rebuild it.
    drop_if_exists index(:storage_objects, [],
                     name: :storage_objects_storage_key_pattern_index,
                     concurrently: true
                   )

    create index(:storage_objects, ["storage_key text_pattern_ops"],
             name: :storage_objects_storage_key_pattern_index,
             concurrently: true
           )
  end

  def down do
    drop_if_exists index(:storage_objects, [],
                     name: :storage_objects_storage_key_pattern_index,
                     concurrently: true
                   )
  end
end
