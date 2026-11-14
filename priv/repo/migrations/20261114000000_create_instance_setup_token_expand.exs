defmodule Engram.Repo.Migrations.CreateInstanceSetupTokenExpand do
  use Ecto.Migration

  # phase/expand — the self-host first-run setup token, a singleton row.
  # `Engram.Instance.SetupToken` mints it on boot while no admin exists, prints
  # the raw token to the server log once, and stores only its SHA-256 here. The
  # first `POST /api/auth/register` must present it, and the claim transaction
  # deletes the row.
  #
  # Its own table, not a column on instance_settings: an instance_settings row
  # created before the admin claim would bake in a registration_mode and freeze
  # ENGRAM_DEFAULT_REGISTRATION_MODE (same reason instance_telemetry is split).
  # New table, no backfill: an instance that is already claimed never needs a
  # row, and an unclaimed one gets its row on the boot that applies this.
  # :timestamptz per Squawk's prefer-timestamp-tz; the schema keeps :utc_datetime.
  def change do
    create table(:instance_setup_token, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :token_hash, :text, null: false
      add :inserted_at, :timestamptz, null: false
      add :updated_at, :timestamptz, null: false
    end
  end
end
