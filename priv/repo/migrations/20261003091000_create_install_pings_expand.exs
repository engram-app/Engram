defmodule Engram.Repo.Migrations.CreateInstallPingsExpand do
  use Ecto.Migration

  # phase/expand — SaaS-side collector for the self-host install census. Not a
  # tenant table: no user_id, no RLS. `id` is the install's random uuid;
  # inserted_at = first seen, updated_at = last seen. No IP column, by design.
  #
  # :text and :timestamptz (not varchar(n) / bare `timestamp`) to satisfy
  # Squawk's prefer-text-field and prefer-timestamp-tz rules. Field lengths and
  # enums are validated in `Engram.Telemetry.InstallPing.changeset/2`, the only
  # writer. The schema keeps :utc_datetime; Ecto reads timestamptz as a UTC
  # DateTime.
  def change do
    create table(:install_pings, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :version, :text, null: false
      add :os, :text, null: false
      add :arch, :text, null: false
      add :runtime, :text, null: false
      add :inserted_at, :timestamptz, null: false
      add :updated_at, :timestamptz, null: false
    end
  end
end
