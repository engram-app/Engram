defmodule Engram.Repo.Migrations.AddUniqueUserAgreements do
  use Ecto.Migration

  def up do
    # Dedupe pre-existing rows by keeping the earliest acceptance per
    # (user_id, document, version). The gate reads only the latest version,
    # so older duplicates are unobservable — safe to drop.
    execute """
    DELETE FROM user_agreements a
    USING user_agreements b
    WHERE a.user_id = b.user_id
      AND a.document = b.document
      AND a.version = b.version
      AND a.id > b.id
    """

    create unique_index(:user_agreements, [:user_id, :document, :version],
             name: :user_agreements_user_document_version_unique
           )
  end

  def down do
    drop index(:user_agreements, [:user_id, :document, :version],
           name: :user_agreements_user_document_version_unique
         )
  end
end
