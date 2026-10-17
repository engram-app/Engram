defmodule Engram.Repo.Migrations.BackfillOAuthRefreshTokensSupersededAt do
  use Ecto.Migration

  @moduledoc """
  Data backfill, companion to 20261015050000 (which added the column).

  0.52.0's grace re-issue (#1981) revokes the unused successor it replaces
  but predates `superseded_at`. Stamps `superseded_at = revoked_at` on those
  rows: revoked, never consumed, in a family that still has a live
  (unconsumed, unrevoked) row. A real family revoke marks every live row and
  a single-row leaf revoke leaves none, so neither matches.

  Liveness (`Engram.OAuth.family_unrevoked/1`) already reads such a row as
  superseded, so nothing waits on this; it makes the rows say what they
  mean. `Engram.OAuth.cleanup_expired/0` re-applies it hourly for rows an
  old node writes during a rolling deploy. Idempotent (`superseded_at IS
  NULL`). `oauth_refresh_tokens` is not RLS-tenanted and small.

  `down` is a no-op: the stamped rows are indistinguishable from re-issues
  this release wrote, and rolling back the column drops them all anyway.
  """

  @sql """
  UPDATE oauth_refresh_tokens t
     SET superseded_at = t.revoked_at
   WHERE t.revoked_at IS NOT NULL
     AND t.consumed_at IS NULL
     AND t.superseded_at IS NULL
     AND EXISTS (
       SELECT 1 FROM oauth_refresh_tokens g
        WHERE g.family_id = t.family_id
          AND g.revoked_at IS NULL
          AND g.consumed_at IS NULL
     )
  """

  def statements, do: [@sql]

  def up, do: Enum.each(statements(), &execute/1)

  def down, do: :ok
end
