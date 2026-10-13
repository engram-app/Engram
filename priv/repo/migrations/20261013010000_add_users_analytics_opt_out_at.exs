defmodule Engram.Repo.Migrations.AddUsersAnalyticsOptOutAt do
  use Ecto.Migration

  @moduledoc """
  phase/expand. Nullable column, no default, no backfill: a metadata-only
  ALTER. Set when a user objects to analytics (privacy policy 2026-10-12);
  every PostHog emitter skips that user.
  """

  def change do
    alter table(:users) do
      add :analytics_opt_out_at, :utc_datetime_usec
    end
  end
end
