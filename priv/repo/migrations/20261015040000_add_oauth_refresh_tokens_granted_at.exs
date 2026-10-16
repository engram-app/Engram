defmodule Engram.Repo.Migrations.AddOAuthRefreshTokensGrantedAt do
  use Ecto.Migration

  @moduledoc """
  `oauth_refresh_tokens.granted_at`: when the grant (the refresh-token
  family) was created, copied unchanged onto every rotation successor.
  `Engram.OAuth.granted_at/1` reads it to refuse restoring a vault deleted
  before the grant existed. Deriving it from the family's earliest surviving
  row moved it later each time cleanup deleted an old row.

  Nullable, no default, no backfill: a metadata-only ALTER. `:timestamptz`
  for Squawk (prefer-timestamp-tz); the schema field stays `:utc_datetime_usec`.
  A NULL row (any grant minted before this column, or by a release that
  predates it) falls back to the family's earliest `inserted_at`, and its
  next rotation stores that value, so the column fills itself in without an
  operator step.
  """

  def change do
    alter table(:oauth_refresh_tokens) do
      add :granted_at, :timestamptz
    end
  end
end
