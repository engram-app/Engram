defmodule Engram.Repo.Migrations.AddPhoneVerifiedAtToUsers do
  use Ecto.Migration

  # Pricing v2 §A — phone gate for EmbedNote worker + future publish/share.
  # Populated by Clerk `user.updated` webhook when phone_numbers[].verification.status
  # flips to "verified". No backfill — pre-existing users go through Clerk OTP
  # next time they want to embed.
  def change do
    alter table(:users) do
      add :phone_verified_at, :utc_datetime_usec
    end
  end
end
