defmodule EngramWeb.ChannelOAuthScopeTest do
  @moduledoc """
  A vault-scoped OAuth grant must bind the WebSocket path, not just HTTP.

  Plugs do not run for a socket connect, so `OAuthScopeEnforce` never fires
  here — before this the channels checked only the API key's vault access and
  a token granted vault A joined vault B's `sync:`/`crdt:` topic, which is the
  live note-sync path streaming document content.

  Every socket here comes through the real `UserSocket.connect/3` with a real
  minted token: the scope must be derived from the VERIFIED token, so a test
  that hand-assigns it would prove nothing.

  Since audience binding (#1997) an access token from `/oauth/token` carries
  `aud: "engram:mcp"` and the socket refuses it at connect (pinned below).
  The tokens here carry the legacy `aud`, as every OAuth token minted before
  that change does: those still verify for their 15-minute life, so the
  channel gates below are what bounds them on the socket.
  """
  use EngramWeb.ChannelCase, async: false

  alias Engram.{Accounts, Crypto, Vaults}

  setup do
    # `external_id` is what the token's `sub` carries; without it the local
    # auth provider rejects our minted token as :missing_claims before any of
    # this is reachable. Same helper shape as the Task 7a plug test.
    user = insert(:user, external_id: "test-#{Ecto.UUID.generate()}")
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, granted, _} = Vaults.register_vault(user, "granted", Ecto.UUID.generate())
    {:ok, ungranted, _} = Vaults.register_vault(user, "ungranted", Ecto.UUID.generate())

    %{user: user, granted: granted, ungranted: ungranted}
  end

  # Mints the same claim shape `Engram.OAuth.issue_access_token/3` mints and
  # connects with it. `vault_ids: nil` is the unrestricted grant.
  defp oauth_socket(user, vault_ids) do
    extras = %{"scope" => "notes:read notes:write"}
    extras = if vault_ids, do: Map.put(extras, "vault_ids", vault_ids), else: extras

    {:ok, socket} =
      connect(EngramWeb.UserSocket, %{"token" => Accounts.generate_jwt(user, extras)})

    socket
  end

  defp join_sync_topic(socket, user, vault),
    do: subscribe_and_join(socket, EngramWeb.SyncChannel, "sync:#{user.id}:#{vault.id}")

  defp join_crdt_topic(socket, user, vault) do
    subscribe_and_join(socket, EngramWeb.CrdtChannel, "crdt:#{user.id}:#{vault.id}", %{
      "crdt_proto" => 2
    })
  end

  defp join_user_topic(socket, user),
    do: subscribe_and_join(socket, EngramWeb.UserChannel, "user:#{user.id}")

  describe "sync: topic" do
    test "a granted vault joins", %{user: user, granted: granted} do
      assert {:ok, _, _} = user |> oauth_socket([granted.id]) |> join_sync_topic(user, granted)
    end

    test "a vault outside the grant is refused", %{
      user: user,
      granted: granted,
      ungranted: ungranted
    } do
      assert {:error, %{reason: "vault_not_found"}} =
               user |> oauth_socket([granted.id]) |> join_sync_topic(user, ungranted)
    end

    test "an unscoped token joins anything", %{user: user, granted: granted, ungranted: ungranted} do
      assert {:ok, _, _} = user |> oauth_socket(nil) |> join_sync_topic(user, granted)
      assert {:ok, _, _} = user |> oauth_socket(nil) |> join_sync_topic(user, ungranted)
    end
  end

  describe "crdt: topic" do
    test "a granted vault joins", %{user: user, granted: granted} do
      assert {:ok, _, _} = user |> oauth_socket([granted.id]) |> join_crdt_topic(user, granted)
    end

    test "a vault outside the grant is refused", %{
      user: user,
      granted: granted,
      ungranted: ungranted
    } do
      assert {:error, %{reason: "vault_not_found"}} =
               user |> oauth_socket([granted.id]) |> join_crdt_topic(user, ungranted)
    end

    test "an unscoped token joins anything", %{user: user, granted: granted, ungranted: ungranted} do
      assert {:ok, _, _} = user |> oauth_socket(nil) |> join_crdt_topic(user, granted)
      assert {:ok, _, _} = user |> oauth_socket(nil) |> join_crdt_topic(user, ungranted)
    end
  end

  # A multi-vault grant is the shape the scalar `vault_id` claim cannot
  # express; both members must join and a third vault must still be refused.
  test "a multi-vault grant admits every listed vault and nothing else", %{
    user: user,
    granted: granted,
    ungranted: ungranted
  } do
    {:ok, third, _} = Vaults.register_vault(user, "third", Ecto.UUID.generate())
    socket = oauth_socket(user, [granted.id, ungranted.id])

    assert {:ok, _, _} = join_sync_topic(socket, user, granted)
    assert {:ok, _, _} = join_sync_topic(socket, user, ungranted)

    assert {:error, %{reason: "vault_not_found"}} =
             join_sync_topic(socket, user, third)
  end

  # Per-vault access levels (#174). Every socket write rides the crdt: channel
  # (sync: and user: accept no inbound writes), so a read-level vault is
  # refused at crdt: join: no crdt_msg, create, rename or delete can reach it.
  describe "per-vault access levels" do
    defp leveled_socket(user, access) do
      extras = %{
        "scope" => "mcp",
        "vault_ids" => Map.keys(access),
        "vault_access" => access
      }

      connect(EngramWeb.UserSocket, %{"token" => Accounts.generate_jwt(user, extras)})
    end

    test "a read-level vault cannot join crdt:", %{user: u, granted: g, ungranted: r} do
      {:ok, socket} = leveled_socket(u, %{g.id => "write", r.id => "read"})

      assert {:error, %{reason: "read_only_vault"}} = join_crdt_topic(socket, u, r)
    end

    test "a write-level vault in the same grant joins crdt:", %{user: u, granted: g, ungranted: r} do
      {:ok, socket} = leveled_socket(u, %{g.id => "write", r.id => "read"})

      assert {:ok, _, _} = join_crdt_topic(socket, u, g)
    end

    test "a read-level vault still joins the read-only sync: topic", %{
      user: u,
      granted: g,
      ungranted: r
    } do
      {:ok, socket} = leveled_socket(u, %{g.id => "write", r.id => "read"})

      assert {:ok, _, _} = join_sync_topic(socket, u, r)
    end

    # A read-only credential still connects: sync: and user: carry no inbound
    # writes and are how it hears about changes. crdt: stays shut.
    test "a grant with no writable vault joins sync: and user:, never crdt:", %{
      user: u,
      granted: g
    } do
      {:ok, socket} = leveled_socket(u, %{g.id => "read"})

      assert {:ok, _, _} = join_sync_topic(socket, u, g)
      assert {:ok, _, _} = join_user_topic(socket, u)
      assert {:error, %{reason: "read_only_vault"}} = join_crdt_topic(socket, u, g)
    end

    test "an all-vaults grant at read level joins sync:, never crdt:", %{user: u, granted: g} do
      token = Accounts.generate_jwt(u, %{"scope" => "mcp", "default_access" => "read"})
      {:ok, socket} = connect(EngramWeb.UserSocket, %{"token" => token})

      assert {:ok, _, _} = join_sync_topic(socket, u, g)
      assert {:error, %{reason: "read_only_vault"}} = join_crdt_topic(socket, u, g)
    end
  end

  # The hand-made tokens above carry `vault_access` in their claims; a real
  # access token carries only `gid`, and its levels come from the grant row.
  # These use the real consent -> /oauth/token chain (re-minted under the
  # legacy `aud`, see the moduledoc), so the levels a join is judged on are
  # the row's, read at join (`ChannelGate.vault_scope/1`).
  describe "per-vault access levels with a real grant token" do
    setup %{user: user} do
      {:ok, none_vault, _} = Vaults.register_vault(user, "none", Ecto.UUID.generate())

      {:ok, client} =
        Engram.OAuth.register_client(%{
          "redirect_uris" => ["https://client.example/cb"],
          "client_name" => "Client"
        })

      %{client: client, none_vault: none_vault}
    end

    defp real_grant(ctx, selection) do
      {verifier, challenge} = Engram.OAuthHelpers.pkce_pair()

      {:ok, validated} =
        Engram.OAuth.validate_authorization_request(%{
          "client_id" => ctx.client.client_id,
          "redirect_uri" => "https://client.example/cb",
          "response_type" => "code",
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "scope" => "mcp"
        })

      {:ok, url} = Engram.OAuth.mint_authorization_code(ctx.user, validated, selection, nil)

      {:ok, tokens} =
        Engram.OAuth.exchange_authorization_code(%{
          "code" => Engram.OAuthHelpers.code_from_redirect(url),
          "redirect_uri" => "https://client.example/cb",
          "client_id" => ctx.client.client_id,
          "code_verifier" => verifier
        })

      {:ok, claims} = Engram.Token.verify(tokens.access_token)
      # The premise: levels are NOT in the token.
      refute Map.has_key?(claims, "vault_access")
      # As minted the token is MCP-bound and never opens a socket; the same
      # claims under the legacy `aud` are a token minted before #1997.
      assert :error = connect(EngramWeb.UserSocket, %{"token" => tokens.access_token})
      legacy = Engram.OAuthHelpers.legacy_audience(ctx.user, tokens.access_token)
      {:ok, socket} = connect(EngramWeb.UserSocket, %{"token" => legacy})
      {socket, claims["gid"]}
    end

    defp narrow(ctx, family, selection),
      do:
        :ok =
          Engram.Connections.update_oauth_grant_access(
            ctx.user,
            ctx.client.client_id,
            family,
            selection
          )

    test "crdt: joins the write vault, refuses the read and none vaults", ctx do
      %{user: u, granted: w, ungranted: r, none_vault: n} = ctx
      {socket, _} = real_grant(ctx, {%{w.id => "write", r.id => "read", n.id => "none"}, "none"})

      assert {:ok, _, _} = join_crdt_topic(socket, u, w)
      assert {:error, %{reason: "read_only_vault"}} = join_crdt_topic(socket, u, r)
      assert {:error, %{reason: "vault_not_found"}} = join_crdt_topic(socket, u, n)
    end

    test "narrowing write -> read on a connected socket refuses the next crdt: join", ctx do
      %{user: u, granted: w} = ctx
      {socket, family} = real_grant(ctx, {%{w.id => "write"}, "none"})
      assert {:ok, _, _} = join_crdt_topic(socket, u, w)

      narrow(ctx, family, {%{w.id => "read"}, "none"})

      assert {:error, %{reason: "read_only_vault"}} = join_crdt_topic(socket, u, w)
    end

    test "narrowing write -> none on a connected socket refuses the next crdt: join", ctx do
      %{user: u, granted: w, ungranted: r} = ctx
      {socket, family} = real_grant(ctx, {%{w.id => "write", r.id => "write"}, "none"})
      assert {:ok, _, _} = join_crdt_topic(socket, u, w)

      narrow(ctx, family, {%{w.id => "none", r.id => "write"}, "none"})

      assert {:error, %{reason: "vault_not_found"}} = join_crdt_topic(socket, u, w)
      assert {:ok, _, _} = join_crdt_topic(socket, u, r)
    end
  end

  # Same model for API keys (#332), and for vaults created after the
  # credential: resolved through the new-vaults policy at join time.
  describe "API keys and vaults created later" do
    # API keys need a plan with API access; this tests scoping, not tiers.
    setup %{user: user} do
      insert(:user_limit_override, user: user, key: "api_rps_cap", value: %{"v" => 100})
      :ok
    end

    defp key_socket(user, access) do
      {:ok, raw, _} = Accounts.create_api_key(user, "k", access)
      connect(EngramWeb.UserSocket, %{"token" => raw})
    end

    defp claims_socket(user, access, default) do
      extras = %{"scope" => "mcp", "vault_access" => access, "default_access" => default}
      connect(EngramWeb.UserSocket, %{"token" => Accounts.generate_jwt(user, extras)})
    end

    test "a read-only API key joins sync: and user:, never crdt:", %{user: u, granted: g} do
      {:ok, socket} = key_socket(u, {%{g.id => "read"}, "read"})

      assert {:ok, _, _} = join_sync_topic(socket, u, g)
      assert {:ok, _, _} = join_user_topic(socket, u)
      assert {:error, %{reason: "read_only_vault"}} = join_crdt_topic(socket, u, g)
    end

    test "an API key's read-level vault cannot join crdt:", %{user: u, granted: g, ungranted: r} do
      {:ok, socket} = key_socket(u, {%{g.id => "write", r.id => "read"}, "none"})

      assert {:error, %{reason: "read_only_vault"}} = join_crdt_topic(socket, u, r)
      assert {:ok, _, _} = join_crdt_topic(socket, u, g)
    end

    for kind <- [:oauth, :api_key] do
      test "#{kind}: a later vault under policy none is refused everywhere", %{
        user: u,
        granted: g
      } do
        {:ok, socket} = later_socket(unquote(kind), u, g, "none")
        {:ok, later, _} = Vaults.register_vault(u, "later", Ecto.UUID.generate())

        assert {:error, %{reason: "vault_not_found"}} = join_sync_topic(socket, u, later)
        assert {:error, _} = join_crdt_topic(socket, u, later)
      end

      test "#{kind}: a later vault under policy read is read-only", %{user: u, granted: g} do
        {:ok, socket} = later_socket(unquote(kind), u, g, "read")
        {:ok, later, _} = Vaults.register_vault(u, "later", Ecto.UUID.generate())

        assert {:ok, _, _} = join_sync_topic(socket, u, later)
        assert {:error, %{reason: "read_only_vault"}} = join_crdt_topic(socket, u, later)
      end

      test "#{kind}: a later vault under policy write joins crdt:", %{user: u, granted: g} do
        {:ok, socket} = later_socket(unquote(kind), u, g, "write")
        {:ok, later, _} = Vaults.register_vault(u, "later", Ecto.UUID.generate())

        assert {:ok, _, _} = join_crdt_topic(socket, u, later)
      end
    end

    defp later_socket(:oauth, u, g, policy), do: claims_socket(u, %{g.id => "write"}, policy)
    defp later_socket(:api_key, u, g, policy), do: key_socket(u, {%{g.id => "write"}, policy})
  end
end
