defmodule Engram.OAuthGrantCacheTest do
  @moduledoc """
  What reaches the `:oauth_grant` cache entry of an OAuth grant (the state
  behind an access token's `gid`): a revoke evicts exactly the families it
  changed, and the `oauth_refresh_tokens_changed` NOTIFY evicts on the node
  that hears it.

  async: false because these assert on the node-wide cache table itself:
  an async test clearing request caches (`DataCase.clear_request_caches/0`)
  would race the assertions. ExUnit runs sync modules after every async one.
  """
  use EngramWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Engram.OAuthHelpers, only: [code_from_redirect: 1, pkce_pair: 0]

  alias Engram.{Accounts, Connections, OAuth}
  alias Engram.OAuth.RefreshToken
  alias Engram.Repo

  @redirect "https://client.example/cb"

  setup do
    user = ensure_external_id(insert(:user))

    {:ok, client} =
      OAuth.register_client(%{"redirect_uris" => [@redirect], "client_name" => "Client"})

    %{user: user, client: client}
  end

  defp grant(ctx, selection) do
    {verifier, challenge} = pkce_pair()

    {:ok, validated} =
      OAuth.validate_authorization_request(%{
        "client_id" => ctx.client.client_id,
        "redirect_uri" => @redirect,
        "response_type" => "code",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "scope" => "mcp"
      })

    {:ok, url} = OAuth.mint_authorization_code(ctx.user, validated, selection, nil)

    {:ok, tokens} =
      OAuth.exchange_authorization_code(%{
        "code" => code_from_redirect(url),
        "redirect_uri" => @redirect,
        "client_id" => ctx.client.client_id,
        "code_verifier" => verifier
      })

    tokens
  end

  defp gid(tokens) do
    {:ok, claims} = Engram.Token.verify(tokens.access_token)
    claims["gid"]
  end

  defp set_row(raw, changes) do
    hash = Engram.Crypto.sha256_hex(raw)

    {1, _} =
      Repo.update_all(from(t in RefreshToken, where: t.token_hash == ^hash), set: changes)
  end

  # ── item 13: eviction is per family ────────────────────────────────

  describe "eviction scope" do
    test "a revoke evicts only the families it changed", ctx do
      mine = grant(ctx, :all)
      other = grant(ctx, :all)
      {:ok, _} = Accounts.grant_claims(mine.access_token)
      {:ok, _} = Accounts.grant_claims(other.access_token)
      assert {:ok, _} = Engram.Cache.get(:oauth_grant, gid(other))

      :ok = Connections.revoke_oauth_grant(ctx.user.id, gid(mine))

      assert Engram.Cache.get(:oauth_grant, gid(mine)) == :miss
      assert {:ok, _} = Engram.Cache.get(:oauth_grant, gid(other))
    end

    test "a revoke that changes nothing evicts nothing", ctx do
      mine = grant(ctx, :all)
      other = grant(ctx, :all)
      :ok = Connections.revoke_oauth_grant(ctx.user.id, gid(mine))
      {:ok, _} = Accounts.grant_claims(other.access_token)

      # Already revoked: 0 rows change.
      :ok = Connections.revoke_oauth_grant(ctx.user.id, gid(mine))

      assert {:ok, _} = Engram.Cache.get(:oauth_grant, gid(other))
    end
  end

  # ── item 11: the NOTIFY handler drops the cached grant ─────────────

  describe "the oauth_refresh_tokens_changed notification" do
    test "evicts that family's cached state on the receiving node", ctx do
      tokens = grant(ctx, :all)
      family = gid(tokens)
      {:ok, _} = Accounts.grant_claims(tokens.access_token)
      assert {:ok, _} = Engram.Cache.get(:oauth_grant, family)

      # Another node revoked it: the row changed, and only the NOTIFY tells us.
      set_row(tokens.refresh_token, revoked_at: DateTime.utc_now(:second))
      # Still served from cache until the notification lands.
      assert {:ok, _} = Accounts.grant_claims(tokens.access_token)

      server = Process.whereis(Engram.Cache.Server)
      send(server, {:notification, self(), nil, "oauth_refresh_tokens_changed", family})
      :sys.get_state(server)

      assert Engram.Cache.get(:oauth_grant, family) == :miss
      assert Accounts.grant_claims(tokens.access_token) == :revoked
    end
  end
end
