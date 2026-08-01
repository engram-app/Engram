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
  # squawk-ignore-file: squawk's `changing-column-type` fires on all three
  # ALTERs and has no per-statement ignore, so the whole file is marked. The
  # rule is generic: it cannot tell a binary-coercible widening from a real type
  # change. Measured on PostgreSQL 18.4 by comparing pg_class.relfilenode before
  # and after (a changed relfilenode means the heap was rewritten):
  #
  #   varchar(255)   -> text     relfilenode UNCHANGED   no rewrite
  #   varchar(255)[] -> text[]   relfilenode CHANGED     FULL REWRITE
  #
  # So the scalar columns are free, and the ARRAY one is not: PostgreSQL's
  # no-rewrite path does not apply at the array level even though the element
  # cast is binary coercible. An earlier version of this comment claimed all
  # three were rewrite-free. That was wrong, and on a large table it would have
  # been an outage.
  #
  # safety_assured: "Two of the three ALTERs are binary-coercible widenings that
  # do not rewrite the heap (verified via relfilenode). The third,
  # oauth_clients.redirect_uris varchar(255)[] -> text[], DOES rewrite the table
  # under ACCESS EXCLUSIVE. It is safe here only because oauth_clients is small:
  # it holds one narrow row per DCR client registration, with no historical
  # accumulation (codes and tokens live in other tables). Widening only, so
  # every existing value stays valid and no reader can observe a narrower type.
  # Incident: Windsurf consent 500, 2026-07-30."
  #
  # BEFORE DEPLOY, confirm the rewrite is still trivial:
  #
  #   SELECT count(*), pg_size_pretty(pg_total_relation_size('oauth_clients'))
  #   FROM oauth_clients;
  #
  # At launch scale this is milliseconds. If that table has grown unexpectedly
  # large, do the array column separately (add text[] column, backfill, swap)
  # rather than taking a long exclusive lock on the OAuth client table, which
  # would block every token exchange for the duration.

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
