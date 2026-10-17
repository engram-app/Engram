defmodule Engram.ConnectionsUpdateAccessTest do
  @moduledoc """
  Changing the vault access of an existing credential from Settings: an OAuth
  grant (`Connections.update_oauth_grant_access/4`) and an API key
  (`Accounts.update_api_key_access/3`). The change must hold for tokens and
  keys already issued, and for every refresh after it.

  async: false: asserts on the node-wide grant cache, like
  `OAuthGrantCacheTest`.
  """
  use EngramWeb.ConnCase, async: false

  import Engram.OAuthHelpers, only: [code_from_redirect: 1, pkce_pair: 0]

  import Ecto.Query, only: [from: 2]

  alias Engram.{Accounts, Connections, OAuth, Permissions, Repo}
  alias Engram.OAuth.RefreshToken

  @redirect "https://client.example/cb"

  setup do
    user = ensure_external_id(insert(:user))
    work = insert(:vault, user: user)
    personal = insert(:vault, user: user)

    {:ok, client} =
      OAuth.register_client(%{"redirect_uris" => [@redirect], "client_name" => "Client"})

    %{user: user, work: work, personal: personal, client: client}
  end

  defp grant(ctx, selection, scope \\ "mcp") do
    {verifier, challenge} = pkce_pair()

    {:ok, validated} =
      OAuth.validate_authorization_request(%{
        "client_id" => ctx.client.client_id,
        "redirect_uri" => @redirect,
        "response_type" => "code",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "scope" => scope
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

  defp scope_of(access_token) do
    {:ok, claims} = Accounts.grant_claims(access_token)
    Permissions.from_claims(claims)
  end

  defp gid(tokens) do
    {:ok, claims} = Engram.Token.verify(tokens.access_token)
    claims["gid"]
  end

  defp update(ctx, tokens, selection),
    do:
      Connections.update_oauth_grant_access(
        ctx.user,
        ctx.client.client_id,
        gid(tokens),
        selection
      )

  describe "update_oauth_grant_access/4" do
    test "narrows an issued access token at once", ctx do
      tokens = grant(ctx, {%{ctx.work.id => "write", ctx.personal.id => "write"}, "none"})
      assert Permissions.allows_write?(scope_of(tokens.access_token), ctx.work)

      assert :ok = update(ctx, tokens, {%{ctx.work.id => "read"}, "none"})

      scope = scope_of(tokens.access_token)
      assert Permissions.level(scope, ctx.work) == :read
      assert Permissions.level(scope, ctx.personal) == :none
    end

    test "widens: the user can give more than the client was first granted", ctx do
      tokens = grant(ctx, {%{ctx.work.id => "read"}, "none"})

      assert :ok = update(ctx, tokens, {%{ctx.work.id => "write"}, "write"})

      scope = scope_of(tokens.access_token)
      assert Permissions.allows_write?(scope, ctx.work)
      assert Permissions.allows_write?(scope, ctx.personal)
    end

    test "a refresh after the change carries the new access", ctx do
      tokens = grant(ctx, {%{ctx.work.id => "write"}, "none"})
      assert :ok = update(ctx, tokens, {%{ctx.personal.id => "read"}, "none"})

      {:ok, rotated} = OAuth.rotate_refresh_token(tokens.refresh_token, ctx.client.client_id)

      scope = scope_of(rotated.access_token)
      assert Permissions.level(scope, ctx.work) == :none
      assert Permissions.level(scope, ctx.personal) == :read
    end

    test "a grace re-issue of the consumed parent keeps the new access", ctx do
      tokens = grant(ctx, {%{ctx.work.id => "write"}, "none"})
      {:ok, _lost} = OAuth.rotate_refresh_token(tokens.refresh_token, ctx.client.client_id)

      assert :ok = update(ctx, tokens, {%{ctx.work.id => "read"}, "none"})

      # The client never got the first rotation's response and retries.
      {:ok, reissued} = OAuth.rotate_refresh_token(tokens.refresh_token, ctx.client.client_id)
      assert Permissions.level(scope_of(reissued.access_token), ctx.work) == :read
    end

    test "an mcp:read grant cannot be given write", ctx do
      tokens = grant(ctx, {%{ctx.work.id => "read"}, "none"}, "mcp:read")

      assert {:error, :read_only_grant} =
               update(ctx, tokens, {%{ctx.work.id => "write"}, "none"})

      assert {:error, :read_only_grant} = update(ctx, tokens, {%{}, "write"})
      assert :ok = update(ctx, tokens, {%{ctx.personal.id => "read"}, "none"})
      assert Permissions.level(scope_of(tokens.access_token), ctx.personal) == :read
    end

    test "a vault that is not the user's is refused and nothing changes", ctx do
      tokens = grant(ctx, {%{ctx.work.id => "write"}, "none"})
      foreign = insert(:vault, user: insert(:user))

      assert {:error, :invalid_access} = update(ctx, tokens, {%{foreign.id => "read"}, "none"})
      assert Permissions.allows_write?(scope_of(tokens.access_token), ctx.work)
    end

    test "another user's grant, a revoked one, or the wrong client is not found", ctx do
      tokens = grant(ctx, {%{ctx.work.id => "write"}, "none"})
      selection = {%{ctx.work.id => "read"}, "none"}
      other = ensure_external_id(insert(:user))

      assert {:error, :not_found} =
               Connections.update_oauth_grant_access(
                 other,
                 ctx.client.client_id,
                 gid(tokens),
                 selection
               )

      assert {:error, :not_found} =
               Connections.update_oauth_grant_access(
                 ctx.user,
                 Ecto.UUID.generate(),
                 gid(tokens),
                 selection
               )

      :ok = Connections.revoke_oauth_grant(ctx.user.id, gid(tokens))
      assert {:error, :not_found} = update(ctx, tokens, selection)
    end

    # A family already dead (a revoked, used row) can still hold an unrevoked
    # leaf: a release that revoked one row, or a successor that raced a revoke.
    # Editing it must be a clean not-found that writes nothing.
    test "a dead family with a stray unrevoked row is not found and unchanged", ctx do
      tokens = grant(ctx, {%{ctx.work.id => "write"}, "none"})
      {:ok, _leaf} = OAuth.rotate_refresh_token(tokens.refresh_token, ctx.client.client_id)

      {1, _} =
        Repo.update_all(
          from(t in RefreshToken,
            where: t.family_id == ^gid(tokens) and not is_nil(t.consumed_at)
          ),
          set: [revoked_at: DateTime.utc_now()]
        )

      before =
        Repo.all(
          from(t in RefreshToken,
            where: t.family_id == ^gid(tokens),
            select: t.vault_access
          )
        )

      assert {:error, :not_found} = update(ctx, tokens, {%{ctx.work.id => "read"}, "none"})

      assert before ==
               Repo.all(
                 from(t in RefreshToken,
                   where: t.family_id == ^gid(tokens),
                   select: t.vault_access
                 )
               )
    end
  end

  describe "update_api_key_access/3" do
    test "changes a leveled key's access in place, effective at once", ctx do
      {:ok, raw, key} =
        Accounts.create_api_key(ctx.user, "k", {%{ctx.work.id => "write"}, "none"})

      {:ok, _user, before} = Accounts.validate_api_key(raw)

      assert Permissions.allows_write?(
               Permissions.vault_scope(%{current_api_key: before}),
               ctx.work
             )

      assert {:ok, _} =
               Accounts.update_api_key_access(
                 ctx.user,
                 key.id,
                 {%{ctx.work.id => "read", ctx.personal.id => "write"}, "none"}
               )

      {:ok, _user, now} = Accounts.validate_api_key(raw)
      scope = Permissions.vault_scope(%{current_api_key: now})
      assert Permissions.level(scope, ctx.work) == :read
      assert Permissions.level(scope, ctx.personal) == :write
    end

    test "a pre-levels key is refused: its hash would widen on a rollback", ctx do
      {:ok, _raw, key} = Accounts.create_api_key(ctx.user, "old")

      assert {:error, :legacy_key} =
               Accounts.update_api_key_access(
                 ctx.user,
                 key.id,
                 {%{ctx.work.id => "read"}, "none"}
               )
    end

    test "another user's key is not found", ctx do
      {:ok, _raw, key} =
        Accounts.create_api_key(ctx.user, "k", {%{ctx.work.id => "write"}, "none"})

      assert {:error, :not_found} =
               Accounts.update_api_key_access(insert(:user), key.id, {%{}, "read"})
    end

    test "a vault that is not the user's is refused", ctx do
      {:ok, _raw, key} =
        Accounts.create_api_key(ctx.user, "k", {%{ctx.work.id => "write"}, "none"})

      foreign = insert(:vault, user: insert(:user))

      assert {:error, :invalid_access} =
               Accounts.update_api_key_access(ctx.user, key.id, {%{foreign.id => "read"}, "none"})
    end
  end
end
