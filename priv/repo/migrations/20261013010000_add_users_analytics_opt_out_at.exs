defmodule Engram.Repo.Migrations.AddUsersAnalyticsOptOutAt do
  use Ecto.Migration

  @moduledoc """
  phase/expand. Nullable `:timestamptz` (Squawk prefer-timestamp-tz), no
  default, no backfill: a metadata-only ALTER. Set when a user objects to
  analytics (privacy policy 2026-10-12); `Engram.Analytics` then sends nothing
  for them.
  """

  def change do
    alter table(:users) do
      add :analytics_opt_out_at, :timestamptz
    end
  end
end
