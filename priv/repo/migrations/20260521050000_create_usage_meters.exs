defmodule Engram.Repo.Migrations.CreateUsageMeters do
  use Ecto.Migration

  # Pricing v2 §B (lifetime embed budget) — per-user counters.
  # Additional columns (conversations_today, queries_today, last_active_at)
  # land alongside the §C and §D PRs that need them; this migration scopes
  # to the §B lifetime token counter only.
  def change do
    create table(:usage_meters, primary_key: false) do
      add :user_id,
          references(:users, on_delete: :delete_all, type: :bigint),
          primary_key: true

      add :lifetime_embed_tokens, :bigint, null: false, default: 0
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end
  end
end
