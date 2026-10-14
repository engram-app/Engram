defmodule Engram.Repo.Migrations.AddUsersLocale do
  use Ecto.Migration

  # Additive: the user's UI language (a BCP 47 tag the web app or plugin
  # reports), so the backend can localize emails and messages later (#1943)
  # and analytics can segment by language. Nullable; N-1 code ignores it.
  def change do
    alter table(:users) do
      add :locale, :text
    end
  end
end
