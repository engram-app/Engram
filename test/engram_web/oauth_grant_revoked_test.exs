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
end
