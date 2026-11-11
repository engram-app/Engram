defmodule EngramWeb.OAuthGrantRevokedTest do
  @moduledoc """
  Why a grant ended (2026-11-11). Prod showed 2,446 `mcp_oauth_token_failed
  reason=refresh_token_revoked` from about 10 users, and nothing said what had
  ended those grants. Every ending goes through
  `Engram.OAuth.revoke_refresh_tokens/2`, which now requires a `cause:`, and
  each grant it ends leaves one `mcp_oauth_grant_revoked` after commit, joined
  to the token events by `grant_id`.

  Read from our own event log (`analytics_events`), so not async: the flag and
  the buffer are node-wide.
  """
  use EngramWeb.ConnCase, async: false

  import Ecto.Query
  import Engram.OAuthHelpers, only: [code_from_redirect: 1, pkce_pair: 0]

  alias Engram.Analytics.Event
  alias Engram.Analytics.EventLog
  alias Engram.Connections
  alias Engram.OAuth
  alias Engram.OAuth.{AuthorizationCode, RefreshToken}
  alias Engram.Repo

  @redirect "https://claude.ai/api/mcp/auth_callback"
  @event "mcp_oauth_grant_revoked"

  setup do
    prior = Application.get_env(:engram, :analytics_event_log)
    Application.put_env(:engram, :analytics_event_log, true)
    on_exit(fn -> Application.put_env(:engram, :analytics_event_log, prior) end)
    EngramWeb.RateLimiter.reset_buckets!()
    :ok = EventLog.flush()
    Repo.delete_all(Event)

    {:ok, client} =
      OAuth.register_client(%{"redirect_uris" => [@redirect], "client_name" => "Claude"})

    %{client: client, user: insert(:user)}
  end

  defp events(name) do
    :ok = EventLog.flush()
    Repo.all(from(e in Event, where: e.event == ^name, order_by: e.inserted_at))
  end

  defp code_for(client, user) do
    {verifier, challenge} = pkce_pair()

    {:ok, validated} =
      OAuth.validate_authorization_request(%{
        "client_id" => client.client_id,
        "redirect_uri" => @redirect,
        "response_type" => "code",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "state" => "s",
        "scope" => "mcp"
      })

    {:ok, url} = OAuth.mint_authorization_code(user, validated, :all, nil)
    {code_from_redirect(url), verifier}
  end

  defp exchange_body(client, code, verifier) do
    %{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => @redirect,
      "client_id" => client.client_id,
      "code_verifier" => verifier
    }
  end

  # A live grant over HTTP: its raw refresh token and family id.
  defp grant(client, user) do
    {code, verifier} = code_for(client, user)

    %{"refresh_token" => rt} =
      build_conn()
      |> post("/oauth/token", exchange_body(client, code, verifier))
      |> json_response(200)

    {rt, row(rt).family_id}
  end

  defp refresh(client, rt, user_agent \\ "codex-mcp-client/0.163.0") do
    build_conn()
    |> put_req_header("user-agent", user_agent)
    |> post("/oauth/token", %{
      "grant_type" => "refresh_token",
      "refresh_token" => rt,
      "client_id" => client.client_id
    })
  end

  defp row(raw) do
    hash = Engram.Crypto.sha256_hex(raw)
    Repo.one!(from(r in RefreshToken, where: r.token_hash == ^hash), skip_tenant_check: true)
  end

  defp age_consumed(raw, seconds) do
    at = DateTime.utc_now() |> DateTime.add(-seconds) |> DateTime.truncate(:second)

    raw
    |> row()
    |> Ecto.Changeset.change(consumed_at: at)
    |> Repo.update!(skip_tenant_check: true)
  end

  defp assert_one(cause, family_id, user) do
    assert [%Event{user_id: user_id, props: props}] = events(@event)
    assert user_id == user.id
    assert props["cause"] == cause
    assert props["grant_id"] == OAuth.grant_id(family_id)
    assert props["client"] == "claude"
    props
  end

  # The wire answer for every refused refresh, before and after this change.
  defp assert_invalid_grant(conn) do
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body) == %{"error" => "invalid_grant"}
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  describe "each ending path names its cause" do
    test "Settings: disconnect the whole app", %{client: client, user: user} do
      {_rt, family_id} = grant(client, user)
      :ok = Connections.revoke_oauth_family(user.id, client.client_id, nil)

      props = assert_one("user_disconnect_client", family_id, user)
      assert props["families"] == 1
    end

    test "Settings: disconnecting an app with two grants ends both, one event each", %{
      client: client,
      user: user
    } do
      {_, f1} = grant(client, user)
      {_, f2} = grant(client, user)
      :ok = Connections.revoke_oauth_family(user.id, client.client_id, nil)

      revoked = events(@event)

      assert Enum.map(revoked, & &1.props["grant_id"]) |> Enum.sort() ==
               Enum.sort([OAuth.grant_id(f1), OAuth.grant_id(f2)])

      assert Enum.all?(revoked, &(&1.props["families"] == 2))
      assert Enum.all?(revoked, &(&1.props["cause"] == "user_disconnect_client"))
    end

    test "Settings: disconnect one grant", %{client: client, user: user} do
      {_rt, family_id} = grant(client, user)
      :ok = Connections.revoke_oauth_grant(user.id, family_id)
      assert_one("user_disconnect_grant", family_id, user)
    end

    test "vault soft delete", %{client: client, user: user} do
      vault = insert(:vault, user: user)

      grant =
        insert(:oauth_refresh_token,
          user_id: user.id,
          client_id: client.client_id,
          vault_id: vault.id,
          vault_ids: [vault.id]
        )

      assert {:ok, _} = Engram.Vaults.delete_vault(user, vault.id)
      assert_one("vault_deleted", grant.family_id, user)
    end

    test "vault purge's pass names its own cause", %{client: client, user: user} do
      vault = insert(:vault, user: user)

      grant =
        insert(:oauth_refresh_token,
          user_id: user.id,
          client_id: client.client_id,
          vault_id: vault.id,
          vault_ids: [vault.id]
        )

      assert Connections.drop_vault_from_grants(user.id, vault.id, cause: :vault_purged) == 1
      assert_one("vault_purged", grant.family_id, user)
    end

    test "RFC 7009 revoke by the app, response unchanged", %{client: client, user: user} do
      {rt, family_id} = grant(client, user)

      conn =
        post(build_conn(), "/oauth/revoke", %{
          "token" => rt,
          "token_type_hint" => "refresh_token",
          "client_id" => client.client_id
        })

      assert conn.status == 200
      assert conn.resp_body == ""
      assert_one("client_revoke_rfc7009", family_id, user)
    end

    test "a used token replayed outside the grace window", %{client: client, user: user} do
      {rt1, family_id} = grant(client, user)
      assert refresh(client, rt1).status == 200
      age_consumed(rt1, 120)

      assert_invalid_grant(refresh(client, rt1))

      props = assert_one("refresh_reuse", family_id, user)
      assert props["client_agent"] == "codex"
      assert props["families"] == 1
    end

    test "a used token of an already-ended family", %{client: client, user: user} do
      {rt1, family_id} = grant(client, user)
      %{"refresh_token" => rt2} = json_response(refresh(client, rt1), 200)

      # The live leaf ended some way that marked only its own row.
      rt2
      |> row()
      |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:second))
      |> Repo.update!(skip_tenant_check: true)

      assert_invalid_grant(refresh(client, rt1))
      assert_one("revoked_after_use", family_id, user)
    end

    test "a successor a grace re-issue replaced, presented later", %{client: client, user: user} do
      {rt1, family_id} = grant(client, user)
      %{"refresh_token" => rt2} = json_response(refresh(client, rt1), 200)
      # Inside the grace window: re-issued, rt2 superseded, the family lives.
      assert refresh(client, rt1).status == 200
      assert events(@event) == []

      assert_invalid_grant(refresh(client, rt2))
      assert_one("superseded_reuse", family_id, user)
    end

    test "an authorization code replayed past the grace window", %{client: client, user: user} do
      {code, verifier} = code_for(client, user)

      build_conn()
      |> post("/oauth/token", exchange_body(client, code, verifier))
      |> json_response(200)

      [code_row] =
        Repo.all(from(c in AuthorizationCode, where: c.user_id == ^user.id),
          skip_tenant_check: true
        )

      at = DateTime.utc_now() |> DateTime.add(-120) |> DateTime.truncate(:second)
      code_row |> Ecto.Changeset.change(consumed_at: at) |> Repo.update!(skip_tenant_check: true)

      conn = build_conn() |> post("/oauth/token", exchange_body(client, code, verifier))
      assert conn.status == 400
      assert Jason.decode!(conn.resp_body) == %{"error" => "invalid_grant"}

      assert_one("code_replay", code_row.id, user)
    end
  end

  describe "no ending, no event" do
    test "a second disconnect of an ended grant emits nothing more", %{client: client, user: user} do
      {_rt, family_id} = grant(client, user)
      :ok = Connections.revoke_oauth_grant(user.id, family_id)
      :ok = Connections.revoke_oauth_grant(user.id, family_id)
      assert length(events(@event)) == 1
    end

    test "retries of a dead token emit nothing", %{client: client, user: user} do
      {rt, family_id} = grant(client, user)
      :ok = Connections.revoke_oauth_grant(user.id, family_id)

      for _ <- 1..3, do: assert_invalid_grant(refresh(client, rt))
      assert length(events(@event)) == 1
    end
  end

  test "a revoke without a cause is refused", %{user: user} do
    assert_raise KeyError, ~r/:cause/, fn ->
      OAuth.revoke_refresh_tokens(from(t in RefreshToken, where: t.user_id == ^user.id), [])
    end
  end

  test "a cause outside the closed set is refused", %{user: user} do
    assert_raise ArgumentError, fn ->
      OAuth.revoke_refresh_tokens(from(t in RefreshToken, where: t.user_id == ^user.id),
        cause: :because
      )
    end
  end

  # The response a client sees, captured on base `a12733340` (2026-11-11) and
  # pinned here: status, every header but `x-request-id` (the only volatile
  # one; values differ per request), and the raw body bytes.
  @json_headers [
    {"access-control-allow-headers",
     "authorization, content-type, x-vault-id, x-device-id, x-idempotency-key, traceparent, if-none-match"},
    {"access-control-allow-methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS"},
    {"access-control-allow-origin", "*"},
    {"access-control-expose-headers", "retry-after"},
    {"access-control-max-age", "86400"},
    {"cache-control", "no-store"},
    {"content-security-policy", "default-src 'none'; frame-ancestors 'none'; base-uri 'none'"},
    {"content-type", "application/json; charset=utf-8"},
    {"referrer-policy", "origin"},
    {"x-content-type-options", "nosniff"},
    {"x-frame-options", "DENY"},
    {"x-permitted-cross-domain-policies", "none"}
  ]

  @revoke_headers @json_headers
                  |> List.keydelete("content-type", 0)
                  |> List.keyreplace(
                    "cache-control",
                    0,
                    {"cache-control", "max-age=0, private, must-revalidate"}
                  )

  defp stable_headers(conn),
    do: conn.resp_headers |> List.keydelete("x-request-id", 0) |> Enum.sort()

  describe "responses are unchanged" do
    test "a refused refresh", %{client: client, user: user} do
      {rt, family_id} = grant(client, user)
      :ok = Connections.revoke_oauth_grant(user.id, family_id)
      conn = refresh(client, rt)

      assert conn.status == 400
      assert conn.resp_body == ~s({"error":"invalid_grant"})
      assert stable_headers(conn) == @json_headers
    end

    test "a successful refresh", %{client: client, user: user} do
      {rt, _family_id} = grant(client, user)
      conn = refresh(client, rt)

      assert conn.status == 200
      assert stable_headers(conn) == @json_headers
      body = Jason.decode!(conn.resp_body)

      assert Map.keys(body) |> Enum.sort() ==
               ~w(access_token expires_in refresh_token scope token_type)

      assert body["token_type"] == "Bearer"
      assert body["expires_in"] == 900
      assert body["scope"] == "mcp"
    end

    test "/oauth/revoke", %{client: client, user: user} do
      {rt, _family_id} = grant(client, user)

      conn =
        post(build_conn(), "/oauth/revoke", %{
          "token" => rt,
          "token_type_hint" => "refresh_token",
          "client_id" => client.client_id
        })

      assert conn.status == 200
      assert conn.resp_body == ""
      assert stable_headers(conn) == @revoke_headers
    end
  end

  describe "mcp_oauth_token_failed on refresh" do
    test "a refused refresh of a known token carries its grant_id", %{client: client, user: user} do
      {rt, family_id} = grant(client, user)
      :ok = Connections.revoke_oauth_grant(user.id, family_id)

      assert_invalid_grant(refresh(client, rt))

      assert [%Event{props: props}] = events("mcp_oauth_token_failed")
      assert props["reason"] == "refresh_token_revoked"
      assert props["grant_id"] == OAuth.grant_id(family_id)
    end

    test "an unknown token has no grant, so no grant_id", %{client: client} do
      assert_invalid_grant(refresh(client, "engram_oauth_rt_nope"))

      assert [%Event{props: props}] = events("mcp_oauth_token_failed")
      assert props["reason"] == "refresh_token_unknown"
      refute Map.has_key?(props, "grant_id")
    end
  end

  # Review of #2565: with no transaction owning the after-commit queue, the
  # event ran inline between the revoke and `grants_changed/1`, so a raise in
  # analytics skipped the cache eviction, the socket drop and (whole-app with
  # a vault) the second revoke. A poisoned `:user` cache entry makes
  # `Engram.Analytics` raise, as in `onboarding_test.exs`.
  describe "analytics that raises cannot stop a revoke" do
    setup %{user: user} do
      on_exit(fn -> Engram.Cache.evict(:user, user.id) end)
      Phoenix.PubSub.subscribe(Engram.PubSub, "user_socket:#{user.id}")
      :ok
    end

    defp poison(user), do: Engram.Cache.put(:user, user.id, :not_a_user)

    defp revoked?(%RefreshToken{id: id}),
      do: Repo.get(RefreshToken, id, skip_tenant_check: true).revoked_at != nil

    test "Settings: whole-app disconnect over a vault still ends every grant", %{
      client: client,
      user: user
    } do
      vault = insert(:vault, user: user)

      legacy =
        insert(:oauth_refresh_token,
          user_id: user.id,
          client_id: client.client_id,
          vault_id: vault.id,
          vault_ids: [vault.id]
        )

      leveled =
        insert(:oauth_refresh_token,
          user_id: user.id,
          client_id: client.client_id,
          vault_ids: ["00000000-0000-0000-0000-000000000000"],
          vault_access: %{vault.id => "read"},
          default_access: "none"
        )

      for t <- [legacy, leveled], do: Engram.Cache.put(:oauth_grant, t.family_id, :live)
      poison(user)

      assert :ok = Connections.revoke_oauth_family(user.id, client.client_id, vault.id)

      assert revoked?(legacy) and revoked?(leveled)
      assert Engram.Cache.get(:oauth_grant, legacy.family_id) == :miss
      assert Engram.Cache.get(:oauth_grant, leveled.family_id) == :miss
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "Settings: one-grant disconnect", %{client: client, user: user} do
      {_rt, family_id} = grant(client, user)
      Engram.Cache.put(:oauth_grant, family_id, :live)
      poison(user)

      assert :ok = Connections.revoke_oauth_grant(user.id, family_id)
      assert Engram.Cache.get(:oauth_grant, family_id) == :miss
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "/oauth/revoke still answers 200 and evicts", %{client: client, user: user} do
      {rt, family_id} = grant(client, user)
      Engram.Cache.put(:oauth_grant, family_id, :live)
      poison(user)

      conn =
        post(build_conn(), "/oauth/revoke", %{
          "token" => rt,
          "token_type_hint" => "refresh_token",
          "client_id" => client.client_id
        })

      assert conn.status == 200
      assert conn.resp_body == ""
      assert stable_headers(conn) == @revoke_headers
      assert Engram.Cache.get(:oauth_grant, family_id) == :miss
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    # Called directly: the controller's own `mcp_oauth_token_failed` is a
    # separate, pre-existing inline call this change does not touch.
    test "a reuse kill still answers invalid_grant", %{client: client, user: user} do
      {rt1, family_id} = grant(client, user)
      assert refresh(client, rt1).status == 200
      age_consumed(rt1, 120)
      Engram.Cache.put(:oauth_grant, family_id, :live)
      poison(user)

      assert {:error, {:invalid_grant, :refresh_token_reuse}} =
               OAuth.rotate_refresh_token(rt1, client.client_id,
                 user_agent: "codex-mcp-client/0.163.0"
               )

      assert Engram.Cache.get(:oauth_grant, family_id) == :miss
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "a code replay still answers invalid_grant", %{client: client, user: user} do
      {code, verifier} = code_for(client, user)

      build_conn()
      |> post("/oauth/token", exchange_body(client, code, verifier))
      |> json_response(200)

      [code_row] =
        Repo.all(from(c in AuthorizationCode, where: c.user_id == ^user.id),
          skip_tenant_check: true
        )

      at = DateTime.utc_now() |> DateTime.add(-120) |> DateTime.truncate(:second)
      code_row |> Ecto.Changeset.change(consumed_at: at) |> Repo.update!(skip_tenant_check: true)
      poison(user)

      assert {:error, {:invalid_grant, :code_replay_revoked}} =
               OAuth.exchange_authorization_code(exchange_body(client, code, verifier))

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end
  end

  describe "one event per grant per user action" do
    test "a whole-app disconnect over legacy and leveled grants counts each grant once", %{
      client: client,
      user: user
    } do
      vault = insert(:vault, user: user)
      both = Ecto.UUID.generate()

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        vault_id: vault.id,
        vault_ids: [vault.id]
      )

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        vault_ids: ["00000000-0000-0000-0000-000000000000"],
        vault_access: %{vault.id => "read"},
        default_access: "none"
      )

      # One family with a row of each shape (a grant re-leveled mid-lineage).
      for attrs <- [
            [vault_id: vault.id, vault_ids: [vault.id]],
            [
              vault_ids: ["00000000-0000-0000-0000-000000000000"],
              vault_access: %{vault.id => "read"},
              default_access: "none"
            ]
          ] do
        insert(
          :oauth_refresh_token,
          [user_id: user.id, client_id: client.client_id, family_id: both] ++ attrs
        )
      end

      :ok = Connections.revoke_oauth_family(user.id, client.client_id, vault.id)

      revoked = events(@event)
      grant_ids = Enum.map(revoked, & &1.props["grant_id"])
      assert length(revoked) == 3
      assert grant_ids == Enum.uniq(grant_ids)
      assert OAuth.grant_id(both) in grant_ids
      assert Enum.all?(revoked, &(&1.props["families"] == 3))
    end

    test "a vault purge over legacy and leveled grants counts each grant once", %{
      client: client,
      user: user
    } do
      vault = insert(:vault, user: user)

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        vault_id: vault.id,
        vault_ids: [vault.id]
      )

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        vault_ids: ["00000000-0000-0000-0000-000000000000"],
        vault_access: %{vault.id => "read"},
        default_access: "none"
      )

      assert Connections.drop_vault_from_grants(user.id, vault.id, cause: :vault_purged) == 2

      revoked = events(@event)
      assert length(revoked) == 2
      assert Enum.all?(revoked, &(&1.props["families"] == 2))
    end
  end

  describe "rolled back, nothing ended" do
    test "a revoke inside a transaction that rolls back emits nothing", %{
      client: client,
      user: user
    } do
      vault = insert(:vault, user: user)

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        vault_id: vault.id,
        vault_ids: [vault.id]
      )

      {_rt, family_id} = grant(client, user)

      {:error, :undo} =
        Repo.transaction_after_commit(fn ->
          1 = Connections.drop_vault_from_grants(user.id, vault.id, cause: :vault_purged)
          :ok = Connections.revoke_oauth_grant(user.id, family_id)
          Repo.rollback(:undo)
        end)

      assert events(@event) == []
    end
  end

  # The grant id rides the request process, which a keep-alive connection
  # (and this test) reuses: one request's grant must not label the next.
  test "a grant_id does not carry over to the next request", %{client: client, user: user} do
    {rt, family_id} = grant(client, user)
    :ok = Connections.revoke_oauth_grant(user.id, family_id)
    assert_invalid_grant(refresh(client, rt))

    {:error, _} = OAuth.rotate_refresh_token(rt, client.client_id)
    assert_invalid_grant(refresh(client, "engram_oauth_rt_nope"))

    [known, unknown] = events("mcp_oauth_token_failed")
    assert known.props["grant_id"] == OAuth.grant_id(family_id)
    refute Map.has_key?(unknown.props, "grant_id")
  end

  # The token controller's own `mcp_oauth_token_failed` is attributed to the
  # token's user, so a raising re-read reached the response: a 500 where
  # RFC 6749 says 400. `Engram.Analytics` now keeps its "never raises".
  test "a refused refresh is still a 400 when analytics raises", %{client: client, user: user} do
    {rt, family_id} = grant(client, user)
    :ok = Connections.revoke_oauth_grant(user.id, family_id)
    Engram.Cache.put(:user, user.id, :not_a_user)
    on_exit(fn -> Engram.Cache.evict(:user, user.id) end)

    conn = refresh(client, rt)
    assert conn.status == 400
    assert conn.resp_body == ~s({"error":"invalid_grant"})
    assert stable_headers(conn) == @json_headers
  end
end
