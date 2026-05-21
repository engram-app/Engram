defmodule Engram.Repo.Migrations.UniqueNormalizedEmail do
  use Ecto.Migration

  # Pricing v2 §A — promote the non-unique index to UNIQUE so the database
  # is the source of truth for the multi-account-farming defense. Existing
  # rows whose normalized_email is NULL coexist (SQL UNIQUE treats NULLs as
  # distinct). New writes go through Engram.Auth.EmailNormalizer.normalize/1
  # in Accounts.{find_or_create_by_external_id, create_user_with_password}/*.
  def change do
    drop index(:users, [:normalized_email])
    create unique_index(:users, [:normalized_email])
  end
end
