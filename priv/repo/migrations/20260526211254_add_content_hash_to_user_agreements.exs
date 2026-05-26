defmodule Engram.Repo.Migrations.AddContentHashToUserAgreements do
  use Ecto.Migration

  def change do
    alter table(:user_agreements) do
      add :content_hash, :text
    end
  end
end
