defmodule Engram.Repo.Migrations.AddFounderCodeFlagsToUsers do
  use Ecto.Migration

  # Pricing v2 §F — one-time-per-Clerk-identity founder-code redemption
  # and OG-waitlist grandfather redemption. Both stamped once, never reset,
  # so churn-and-resubscribe can't claim either rate twice.
  def change do
    alter table(:users) do
      add :founder_code_redeemed_at, :utc_datetime_usec
      add :og_grandfather_redeemed_at, :utc_datetime_usec
    end
  end
end
