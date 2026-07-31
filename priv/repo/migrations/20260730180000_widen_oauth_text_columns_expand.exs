defmodule Engram.Repo.Migrations.WidenOauthTextColumnsExpand do
  use Ecto.Migration

  # phase/expand: widen OAuth columns that hold client-supplied strings.
  #
  # Prod 500 on 2026-07-30 connecting Windsurf:
  #   (Postgrex.Error) 22001 value too long for type character varying(255)
  #   at Engram.OAuth.mint_authorization_code/3
  #
  # `state` is client-supplied and RFC 6749 places no bound on it; IDE clients
  # routinely pack routing data into it. It was varchar(255), so a long state
  # crashed consent with a 500 instead of completing the handshake. The
  # application now caps it (see Engram.OAuth), but the column must hold what
  # the cap allows.
  #
  # `redirect_uri` columns were the same class of bug in reverse: DCR validation
  # accepts URIs up to 2048 bytes, so we were accepting values we could not
  # store. `oauth_clients.redirect_uris` failed at registration and
  # `oauth_authorization_codes.redirect_uri` would have failed at mint.
  #
  # safety_assured: "varchar(N) -> text is binary-coercible in PostgreSQL and
  # does NOT rewrite the table or take a long ACCESS EXCLUSIVE lock (the
  # constraint is simply dropped). Widening only: every existing value remains
  # valid, and no reader can observe a narrower type. Incident: Windsurf
  # consent 500, 2026-07-30."

  def up do
    execute "ALTER TABLE oauth_authorization_codes ALTER COLUMN state TYPE text"
    execute "ALTER TABLE oauth_authorization_codes ALTER COLUMN redirect_uri TYPE text"

    # The array default is typed, so it must be dropped before the element type
    # changes and restored afterwards.
    execute "ALTER TABLE oauth_clients ALTER COLUMN redirect_uris DROP DEFAULT"
    execute "ALTER TABLE oauth_clients ALTER COLUMN redirect_uris TYPE text[]"
    execute "ALTER TABLE oauth_clients ALTER COLUMN redirect_uris SET DEFAULT ARRAY[]::text[]"
  end

  # Narrowing back can only succeed while no row exceeds 255. That holds on a
  # fresh CI database (the rollback gate) and on any deployment that has not yet
  # taken a long value; it is deliberately not forced, because silently
  # truncating a redirect_uri or state would corrupt live grants.
  def down do
    execute "ALTER TABLE oauth_clients ALTER COLUMN redirect_uris DROP DEFAULT"

    execute "ALTER TABLE oauth_clients ALTER COLUMN redirect_uris TYPE character varying(255)[]"

    execute "ALTER TABLE oauth_clients ALTER COLUMN redirect_uris SET DEFAULT ARRAY[]::character varying[]"

    execute "ALTER TABLE oauth_authorization_codes ALTER COLUMN redirect_uri TYPE character varying(255)"

    execute "ALTER TABLE oauth_authorization_codes ALTER COLUMN state TYPE character varying(255)"
  end
end
