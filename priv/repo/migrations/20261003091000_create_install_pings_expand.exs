defmodule Engram.Repo.Migrations.CreateInstallPingsExpand do
  use Ecto.Migration

  # phase/expand — SaaS-side collector for the self-host install census. Not a
  # tenant table: no user_id, no RLS. `id` is the install's random uuid;
  # inserted_at = first seen, updated_at = last seen. No IP column, by design.
  def change do
    create table(:install_pings, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :version, :string, size: 32, null: false
      add :os, :string, null: false
      add :arch, :string, null: false
      add :runtime, :string, null: false
      timestamps(type: :utc_datetime)
    end
  end
end
