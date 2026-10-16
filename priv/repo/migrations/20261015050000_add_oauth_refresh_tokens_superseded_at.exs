defmodule Engram.Repo.Migrations.AddOAuthRefreshTokensSupersededAt do
  use Ecto.Migration

  @moduledoc """
  `oauth_refresh_tokens.superseded_at`: set, together with `revoked_at`, on
  an unused rotation successor that a grace-window re-issue (#1974) replaced.
  Such a row can never mint (presented later, it revokes the family), but it
  must not revoke its family: liveness is "no revoked row in the family"
  (`Engram.OAuth.family_unrevoked/1`, #174), and the re-issued successor is
  the same grant.

  Nullable, no default, no backfill: a metadata-only ALTER. `:timestamptz`
  for Squawk (prefer-timestamp-tz). phase/expand: purely additive.
  """

  def change do
    alter table(:oauth_refresh_tokens) do
      add :superseded_at, :timestamptz
    end
  end
end
