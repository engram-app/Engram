defmodule EngramWeb.GrantRevocationSocketTest do
  @moduledoc """
  A revoked OAuth grant must lose its live sockets, on EVERY revocation path,
  not only RFC 7009: the connections page (one grant, and client-wide with or
  without a vault), vault soft delete, the purge pass and refresh-token
  replay. Each path disconnects the owner's sockets (`user_socket:<id>`,
  `Engram.Auth.SessionInvalidator`), and a socket still connected with the
  grant's token is refused at `crdt:` join, which re-reads the grant.

  Sockets come through the real `UserSocket.connect/3` with an access token
  from the real consent -> exchange chain, re-minted under the legacy `aud`
  (`Engram.OAuthHelpers.legacy_audience/2`). A token minted now carries
  `engram:mcp` and the socket refuses it at connect (#1997, pinned below), so
  the only grant tokens a socket can still hold are those minted before that
  change, within their 15-minute life. These tests pin the guards for them;
  the disconnect broadcasts fire whatever token the socket holds.
  """
  use EngramWeb.ChannelCase, async: false

  import Engram.OAuthHelpers, only: [code_from_redirect: 1, legacy_audience: 2, pkce_pair: 0]

  alias Engram.{Accounts, Connections, OAuth, Vaults}

  @redirect "https://client.example/cb"

  setup do
    user = insert(:user, external_id: "test-#{Ecto.UUID.generate()}")
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, a, _} = Vaults.register_vault(user, "A", Ecto.UUID.generate())
    {:ok, b, _} = Vaults.register_vault(user, "B", Ecto.UUID.generate())

    {:ok, client} =
      OAuth.register_client(%{"redirect_uris" => [@redirect], "client_name" => "Client"})

    topic = "user_socket:#{user.id}"
    EngramWeb.Endpoint.subscribe(topic)

    %{user: user, a: a, b: b, client: client, topic: topic}
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

  defp connect_with(ctx, tokens) do
    {:ok, socket} = connect(EngramWeb.UserSocket, %{"token" => legacy(ctx, tokens)})
    socket
  end

  defp legacy(ctx, tokens), do: legacy_audience(ctx.user, tokens.access_token)

  defp join_crdt(socket, ctx, vault) do
    subscribe_and_join(socket, EngramWeb.CrdtChannel, "crdt:#{ctx.user.id}:#{vault.id}", %{
      "crdt_proto" => 2
    })
  end

  defp join_user(socket, ctx),
    do: subscribe_and_join(socket, EngramWeb.UserChannel, "user:#{ctx.user.id}")

  defp assert_disconnected(ctx) do
    topic = ctx.topic
    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 1_000
  end

  defp refute_disconnected(ctx) do
    topic = ctx.topic
    refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, 100
  end

  describe "the connections page" do
    test "revoking one grant disconnects its socket and refuses crdt: join", ctx do
      tokens = grant(ctx, :all)
      socket = connect_with(ctx, tokens)
      assert {:ok, _, _} = join_crdt(socket, ctx, ctx.a)

      :ok = Connections.revoke_oauth_grant(ctx.user.id, gid(tokens))

      assert_disconnected(ctx)
      assert Accounts.grant_claims(tokens.access_token) == :revoked
      # The socket connected before the revoke: its join re-reads the grant.
      assert {:error, %{reason: "unauthorized"}} = join_crdt(socket, ctx, ctx.b)
      # And it cannot come back.
      assert :error = connect(EngramWeb.UserSocket, %{"token" => legacy(ctx, tokens)})
    end

    test "revoking an already-revoked grant changes nothing and disconnects nobody", ctx do
      tokens = grant(ctx, :all)
      :ok = Connections.revoke_oauth_grant(ctx.user.id, gid(tokens))
      assert_disconnected(ctx)

      :ok = Connections.revoke_oauth_grant(ctx.user.id, gid(tokens))
      refute_disconnected(ctx)
    end

    test "a client-wide revoke disconnects", ctx do
      tokens = grant(ctx, :all)
      :ok = Connections.revoke_oauth_family(ctx.user.id, ctx.client.client_id, nil)
      assert_disconnected(ctx)
      assert Accounts.grant_claims(tokens.access_token) == :revoked
    end

    test "a client-wide revoke scoped to a vault takes a leveled grant reaching it", ctx do
      tokens = grant(ctx, {%{ctx.a.id => "read"}, "none"})
      socket = connect_with(ctx, tokens)

      :ok = Connections.revoke_oauth_family(ctx.user.id, ctx.client.client_id, ctx.a.id)

      assert_disconnected(ctx)
      assert Accounts.grant_claims(tokens.access_token) == :revoked
      assert {:error, %{reason: "unauthorized"}} = join_crdt(socket, ctx, ctx.a)
    end
  end

  describe "editing access" do
    test "narrowing a grant disconnects its sockets", ctx do
      tokens = grant(ctx, {%{ctx.a.id => "write", ctx.b.id => "write"}, "none"})
      _socket = connect_with(ctx, tokens)

      :ok =
        Connections.update_oauth_grant_access(
          ctx.user,
          ctx.client.client_id,
          gid(tokens),
          {%{ctx.a.id => "read"}, "none"}
        )

      assert_disconnected(ctx)
    end

    test "a refused edit disconnects nobody", ctx do
      tokens = grant(ctx, {%{ctx.a.id => "write"}, "none"})
      other = insert(:user, external_id: "test-#{Ecto.UUID.generate()}")

      {:error, :not_found} =
        Connections.update_oauth_grant_access(
          other,
          ctx.client.client_id,
          gid(tokens),
          {%{ctx.a.id => "read"}, "none"}
        )

      refute_disconnected(ctx)
    end

    test "narrowing a key disconnects its sockets", ctx do
      {:ok, _raw, key} = Accounts.create_api_key(ctx.user, "k", {%{ctx.a.id => "write"}, "none"})

      {:ok, _} = Accounts.update_api_key_access(ctx.user, key.id, {%{ctx.a.id => "read"}, "none"})

      assert_disconnected(ctx)
    end
  end

  # The disconnect broadcast is the fast path, not the guard: in these tests
  # the socket struct never receives it, which is exactly a missed broadcast.
  # Every join must re-read the grant as `crdt:` does.
  describe "joins after a missed disconnect broadcast" do
    test "sync: join is refused on a vault narrowed to none", ctx do
      tokens = grant(ctx, {%{ctx.a.id => "write", ctx.b.id => "write"}, "none"})
      socket = connect_with(ctx, tokens)
      assert {:ok, _, _} = join_sync(socket, ctx.user, ctx.a)

      :ok =
        Connections.update_oauth_grant_access(
          ctx.user,
          ctx.client.client_id,
          gid(tokens),
          {%{ctx.a.id => "none", ctx.b.id => "write"}, "none"}
        )

      assert {:error, %{reason: "vault_not_found"}} = join_sync(socket, ctx.user, ctx.a)
      assert {:ok, _, _} = join_sync(socket, ctx.user, ctx.b)
    end

    test "sync: join is refused once the grant is revoked", ctx do
      tokens = grant(ctx, :all)
      socket = connect_with(ctx, tokens)
      :ok = Connections.revoke_oauth_grant(ctx.user.id, gid(tokens))

      assert {:error, %{reason: "unauthorized"}} = join_sync(socket, ctx.user, ctx.a)
    end

    test "user: join is refused once the grant is revoked", ctx do
      tokens = grant(ctx, :all)
      socket = connect_with(ctx, tokens)
      :ok = Connections.revoke_oauth_grant(ctx.user.id, gid(tokens))

      assert {:error, %{reason: "unauthorized"}} = join_user(socket, ctx)
    end

    test "user: a vault narrowed to none after join gets no vault events", ctx do
      tokens = grant(ctx, {%{ctx.a.id => "write", ctx.b.id => "write"}, "none"})
      socket = connect_with(ctx, tokens)
      {:ok, _, _} = join_user(socket, ctx)

      :ok =
        Connections.update_oauth_grant_access(
          ctx.user,
          ctx.client.client_id,
          gid(tokens),
          {%{ctx.a.id => "none", ctx.b.id => "write"}, "none"}
        )

      topic = "user:#{ctx.user.id}"
      EngramWeb.Endpoint.broadcast(topic, "vault_populated", %{vault_id: ctx.a.id})
      EngramWeb.Endpoint.broadcast(topic, "vault_populated", %{vault_id: ctx.b.id})

      b_id = ctx.b.id
      assert_push "vault_populated", %{vault_id: ^b_id}
      a_id = ctx.a.id
      refute_push "vault_populated", %{vault_id: ^a_id}
    end
  end

  describe "vault deletion" do
    test "soft delete revokes a leveled grant that reached only that vault", ctx do
      tokens = grant(ctx, {%{ctx.a.id => "write"}, "none"})
      socket = connect_with(ctx, tokens)

      {:ok, _} = Vaults.delete_vault(ctx.user, ctx.a.id)

      assert_disconnected(ctx)
      assert Accounts.grant_claims(tokens.access_token) == :revoked
      {:ok, _} = Vaults.restore_vault(ctx.user, ctx.a.id)
      assert {:error, %{reason: "unauthorized"}} = join_crdt(socket, ctx, ctx.a)
    end

    test "soft delete narrows a pre-levels grant; its socket cannot join the vault after restore",
         ctx do
      tokens = grant(ctx, [ctx.a.id, ctx.b.id])
      socket = connect_with(ctx, tokens)

      {:ok, _} = Vaults.delete_vault(ctx.user, ctx.b.id)
      assert_disconnected(ctx)
      {:ok, _} = Vaults.restore_vault(ctx.user, ctx.b.id)

      assert {:error, %{reason: "vault_not_found"}} = join_crdt(socket, ctx, ctx.b)
      assert {:ok, _, _} = join_crdt(socket, ctx, ctx.a)
    end

    test "the purge pass disconnects what it revokes", ctx do
      tokens = grant(ctx, {%{ctx.a.id => "write"}, "none"})

      assert Connections.drop_vault_from_grants(ctx.user.id, ctx.a.id) > 0

      assert_disconnected(ctx)
      assert Accounts.grant_claims(tokens.access_token) == :revoked
    end
  end

  describe "connecting with a grant token" do
    defp capture_rejection(fun) do
      ref = "socket-rejected-#{System.unique_integer()}"
      test_pid = self()

      :telemetry.attach(
        ref,
        [:engram, :auth, :rejected],
        fn _event, _measurements, meta, _ -> send(test_pid, {:rejected, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(ref) end)
      ExUnit.CaptureLog.capture_log(fun)
    end

    # Refused like any other failed auth: one log line and one
    # `[:engram, :auth, :rejected]` event, as `Plugs.Auth` emits for HTTP.
    test "a revoked grant's is refused with a grant_revoked rejection event and log line", ctx do
      tokens = grant(ctx, :all)
      :ok = Connections.revoke_oauth_grant(ctx.user.id, gid(tokens))

      log =
        capture_rejection(fn ->
          assert :error = connect(EngramWeb.UserSocket, %{"token" => legacy(ctx, tokens)})
        end)

      assert_receive {:rejected, %{reason: "grant_revoked", source: :socket}}
      assert log =~ "auth rejected"
    end

    # The token as minted now, on a live grant: bound to the MCP server, so
    # the socket refuses it before reading the grant at all.
    test "a live grant's token as minted is refused for its audience", ctx do
      tokens = grant(ctx, :all)
      assert {:ok, _} = Accounts.grant_claims(tokens.access_token)

      log =
        capture_rejection(fn ->
          assert :error = connect(EngramWeb.UserSocket, %{"token" => tokens.access_token})
        end)

      assert_receive {:rejected, %{reason: "wrong_audience", source: :socket}}
      assert log =~ "auth rejected"
      # The same grant's legacy-audience token connects: the refusal above is the audience.
      assert {:ok, _} = connect(EngramWeb.UserSocket, %{"token" => legacy(ctx, tokens)})
    end
  end

  describe "the token endpoints" do
    test "refresh-token replay disconnects", ctx do
      first = grant(ctx, :all)
      {:ok, second} = OAuth.rotate_refresh_token(first.refresh_token, ctx.client.client_id)
      # Using the successor ends #1974's grace window: the replay is reuse.
      {:ok, _third} = OAuth.rotate_refresh_token(second.refresh_token, ctx.client.client_id)
      refute_disconnected(ctx)

      {:error, {:invalid_grant, :refresh_token_reuse}} =
        OAuth.rotate_refresh_token(first.refresh_token, ctx.client.client_id)

      assert_disconnected(ctx)
    end

    test "RFC 7009 revoke disconnects", ctx do
      tokens = grant(ctx, :all)
      :ok = OAuth.revoke_token(tokens.refresh_token, ctx.client.client_id, nil)
      assert_disconnected(ctx)
    end
  end
end
