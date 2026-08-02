defmodule Engram.Repo.Migrations.BackfillRefreshTokenRedirectUriMigrate do
  use Ecto.Migration

  # phase/migrate-data — companion to 20260802020000, which added the column.
  #
  # Existing grants have no recorded redirect: authorization codes are
  # single-use and short-lived, so the evidence of where a code was delivered is
  # gone. Without a backfill every pre-#1204 grant would drop to unverified and
  # lose its vendor logo in the connections list, including the real Claude and
  # ChatGPT ones.
  #
  # UNAMBIGUOUS CASE ONLY. When a client registered exactly one redirect, the
  # grant provably used it: /authorize matches the requested redirect against
  # the registered list, so with a list of one there was nothing else to pick.
  # That is a derivation, not a guess.
  #
  # Clients with two or more registered redirects stay NULL and therefore
  # unverified. That is deliberate, and it is the whole point: a multi-entry
  # list is exactly the shape #1204 exploits, so those are the grants we cannot
  # vouch for. A real multi-redirect vendor client re-verifies for free on its
  # next authorization; an impersonator never does.
  #
  # Idempotent (`IS NULL` guard) and reversible to the pre-migration state.
  # No lock concern: `oauth_refresh_tokens` is small and this touches only rows
  # that exist right now.
  def up do
    execute """
    UPDATE oauth_refresh_tokens t
       SET redirect_uri = c.redirect_uris[1]
      FROM oauth_clients c
     WHERE c.client_id = t.client_id
       AND t.redirect_uri IS NULL
       AND array_length(c.redirect_uris, 1) = 1
    """
  end

  def down do
    execute "UPDATE oauth_refresh_tokens SET redirect_uri = NULL"
  end
end
