defmodule Engram.Repo.Migrations.AddOnboardingProfileToUsers do
  use Ecto.Migration

  # FTUX questionnaire: persist a JSON shape per user capturing
  #   { uses_obsidian: bool, tools: [..], completed_at: iso8601 }
  # The Onboarding context treats `completed_at == nil` as "not yet
  # answered" and gates the dashboard via RequireOnboarding.

  def up do
    alter table(:users) do
      add :onboarding_profile, :map, default: fragment("'{}'::jsonb"), null: false
    end
  end

  def down do
    alter table(:users) do
      remove :onboarding_profile
    end
  end
end
