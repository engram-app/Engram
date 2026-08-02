defmodule Engram.Repo.Migrations.AddRedirectUriToOauthRefreshTokensExpand do
  use Ecto.Migration

  # phase/expand — one nullable text column, no backfill, no index.
  #
  # WHY. `Engram.Connections.LogoAllowlist` decides the "verified" badge from
  # whether a vendor-owned HTTPS host appears in the client's REGISTERED
  # `redirect_uris`. That list can hold several entries, and nothing tied the
  # badge to the redirect a given grant actually used. Public DCR meant anyone
  # could register
  #
  #     ["http://localhost:9999/steal", "https://claude.ai/api/mcp/auth_callback"]
  #
  # authorize with the loopback, receive the code on their own machine, and
  # still appear in the victim's connections list as Claude, verified, wearing
  # Anthropic's logo. See engram-app/Engram#1204.
  #
  # The redirect that was actually used is already known and already validated
  # against the registered list at `/oauth/authorize`, and it is already stored
  # on `oauth_authorization_codes.redirect_uri`. It was simply dropped when the
  # code was exchanged for tokens. This column carries it onto the durable
  # grant so verification can be computed from what happened rather than from
  # what was declared possible.
  #
  # NULLABLE ON PURPOSE, and NULL means unverified. Grants issued before this
  # column existed have no recorded redirect, and it cannot be recovered:
  # authorization codes are single-use and short-lived, so the evidence is
  # gone. A separate phase/migrate-data step backfills only the unambiguous
  # case (clients that registered exactly one redirect, where the grant must
  # have used it). Multi-entry clients stay NULL — which is exactly the shape
  # the attack requires, so failing closed there is the point, not a
  # limitation.
  #
  # `:text`, not `:string`: redirect URIs have no useful length bound, and
  # `oauth_authorization_codes.redirect_uri` is already text (widened in
  # 20260730180000 after Windsurf overran a varchar).
  def change do
    alter table(:oauth_refresh_tokens) do
      add :redirect_uri, :text
    end
  end
end
