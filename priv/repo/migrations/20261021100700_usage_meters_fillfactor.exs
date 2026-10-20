defmodule Engram.Repo.Migrations.UsageMetersFillfactor do
  use Ecto.Migration

  # usage_meters is one hot counter row per user. Its counter updates touch no
  # indexed column, so they are HOT (in place, no index entries) when the
  # page has room; fillfactor 80 keeps that room. SHARE UPDATE EXCLUSIVE, so
  # reads and writes carry on; it applies to pages written from now on.
  # UsageMetersFillfactorTest pins it.
  def up, do: execute("ALTER TABLE usage_meters SET (fillfactor = 80)")
  def down, do: execute("ALTER TABLE usage_meters RESET (fillfactor)")
end
