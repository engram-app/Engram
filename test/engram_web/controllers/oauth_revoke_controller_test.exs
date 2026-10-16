defmodule EngramWeb.OAuthRevokeControllerTest do
  use EngramWeb.ConnCase, async: false

  import Ecto.Query
  import Engram.OAuthHelpers, only: [code_from_redirect: 1, pkce_pair: 0]

  alias Engram.OAuth
  alias Engram.OAuth.RefreshToken
  alias Engram.Repo

  setup_all do
    on_exit(fn ->
      Application.put_env(:engram, :rate_limit_override, 10_000)
    end)

    :ok
  end

  setup do
    EngramWeb.RateLimiter.reset_buckets!()
    Application.put_env(:engram, :rate_limit_override, 10_000)
    :ok
  end

  defp full_flow_refresh_token(conn, auth_method \\ "none") do
    user = insert(:user)

    {:ok, client} =
      OAuth.register_client(%{
        "redirect_uris" => ["https://x/cb"],
        "client_name" => "x",
        "token_endpoint_auth_method" => auth_method
      })

    redirect_uri = hd(client.redirect_uris)
    {verifier, challenge} = pkce_pair()

    {:ok, validated} =
      OAuth.validate_authorization_request(%{
        "client_id" => client.client_id,
        "redirect_uri" => redirect_uri,
        "response_type" => "code",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "state" => "s"
      })

    {:ok, redirect_url} = OAuth.mint_authorization_code(user, validated, :all, nil)
    code = code_from_redirect(redirect_url)

    %{"refresh_token" => rt} =
      json_response(
        post(conn, "/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => redirect_uri,
          "client_id" => client.client_id,
          "client_secret" => client.client_secret,
          "code_verifier" => verifier
        }),
        200
      )

    {client, rt}
  end

  describe "POST /oauth/revoke" do
    test "revokes a refresh token and subsequent refresh fails (RFC 7009)", %{conn: conn} do
      {client, rt} = full_flow_refresh_token(conn)

      revoke =
        post(build_conn(), "/oauth/revoke", %{
          "token" => rt,
          "token_type_hint" => "refresh_token",
          "client_id" => client.client_id
        })

      assert revoke.status == 200

      conn2 =
        post(build_conn(), "/oauth/token", %{
          "grant_type" => "refresh_token",
          "refresh_token" => rt,
          "client_id" => client.client_id
        })

      assert json_response(conn2, 400)["error"] == "invalid_grant"
    end

    # RFC 7009 §2.1: the hint is advisory. A wrong one still revokes.
    test "a wrong token_type_hint still revokes", %{conn: conn} do
      {client, rt} = full_flow_refresh_token(conn)

      assert post(build_conn(), "/oauth/revoke", %{
               "token" => rt,
               "token_type_hint" => "access_token",
               "client_id" => client.client_id
             }).status == 200

      refresh =
        post(build_conn(), "/oauth/token", %{
          "grant_type" => "refresh_token",
          "refresh_token" => rt,
          "client_id" => client.client_id
        })

      assert json_response(refresh, 400)["error"] == "invalid_grant"
    end

    # RFC 7009 §5: the endpoint is rate limited like /oauth/token.
    test "is rate limited per client", %{conn: conn} do
      {client, rt} = full_flow_refresh_token(conn)
      EngramWeb.RateLimiter.reset_buckets!()
      Application.put_env(:engram, :rate_limit_override, 2)
      body = %{"token" => rt, "client_id" => client.client_id}

      statuses = for _ <- 1..3, do: post(build_conn(), "/oauth/revoke", body).status
      assert statuses == [200, 200, 429]
    end

    test "force-disconnects live sockets for the token's owner", %{conn: conn} do
      {client, rt} = full_flow_refresh_token(conn)
      hash = Engram.Crypto.sha256_hex(rt)

      user_id =
        Repo.one!(
          from(r in RefreshToken, where: r.token_hash == ^hash, select: r.user_id),
          skip_tenant_check: true
        )

      topic = "user_socket:#{user_id}"
      EngramWeb.Endpoint.subscribe(topic)

      assert post(build_conn(), "/oauth/revoke", %{
               "token" => rt,
               "client_id" => client.client_id
             }).status == 200

      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
    end

    test "returns 200 for an unknown token (RFC 7009 §2.2)", %{conn: conn} do
      {client, _rt} = full_flow_refresh_token(conn)

      conn =
        post(build_conn(), "/oauth/revoke", %{
          "token" => "engram_oauth_rt_doesnotexist",
          "client_id" => client.client_id
        })

      assert conn.status == 200
    end

    # RFC 7009 §2.1: the endpoint authenticates the client as /oauth/token does,
    # and §2.2.1 answers a failure with RFC 6749 §5.2's `invalid_client`.
    test "401s an unknown client and leaves the token alone", %{conn: conn} do
      {client, rt} = full_flow_refresh_token(conn)

      conn =
        post(build_conn(), "/oauth/revoke", %{
          "token" => rt,
          "client_id" => "00000000-0000-0000-0000-000000000000"
        })

      assert json_response(conn, 401)["error"] == "invalid_client"
      assert {:ok, _} = OAuth.rotate_refresh_token(rt, client.client_id)
    end

    test "a confidential client revokes over HTTP Basic", %{conn: conn} do
      {client, rt} = full_flow_refresh_token(conn, "client_secret_basic")

      revoke =
        build_conn()
        |> put_req_header(
          "authorization",
          Plug.BasicAuth.encode_basic_auth(client.client_id, client.client_secret)
        )
        |> post("/oauth/revoke", %{"token" => rt})

      assert revoke.status == 200
      assert {:error, {:invalid_grant, _}} = OAuth.rotate_refresh_token(rt, client.client_id)
    end

    test "a wrong secret over HTTP Basic is 401 and revokes nothing", %{conn: conn} do
      {client, rt} = full_flow_refresh_token(conn, "client_secret_basic")

      revoke =
        build_conn()
        |> put_req_header(
          "authorization",
          Plug.BasicAuth.encode_basic_auth(client.client_id, "wrong")
        )
        |> post("/oauth/revoke", %{"token" => rt})

      assert json_response(revoke, 401)["error"] == "invalid_client"
      assert get_resp_header(revoke, "www-authenticate") == [~s(Basic realm="oauth")]
      assert {:ok, _} = OAuth.rotate_refresh_token(rt, client.client_id)
    end

    test "does NOT revoke when client_id does not own the token (still 200)", %{conn: conn} do
      {client, rt} = full_flow_refresh_token(conn)

      {:ok, other} =
        OAuth.register_client(%{
          "redirect_uris" => ["https://other/cb"],
          "client_name" => "other"
        })

      revoke =
        post(build_conn(), "/oauth/revoke", %{
          "token" => rt,
          "client_id" => other.client_id
        })

      # RFC 7009: always 200, but the token must NOT have been revoked.
      assert revoke.status == 200
      assert {:ok, _new_pair} = OAuth.rotate_refresh_token(rt, client.client_id)
    end

    # RFC 7009 §2.2.1: access tokens are stateless JWTs we cannot revoke, and a
    # 200 would tell the client it had. It expires in 15 minutes on its own.
    test "an access token is unsupported_token_type", %{conn: conn} do
      {client, _rt} = full_flow_refresh_token(conn)
      access = Engram.Accounts.generate_jwt(insert(:user), %{"aud" => "engram:mcp"})

      conn =
        post(build_conn(), "/oauth/revoke", %{"token" => access, "client_id" => client.client_id})

      assert json_response(conn, 400)["error"] == "unsupported_token_type"
    end

    # RFC 7009 §2.2.1 / RFC 6749 §5.2: a missing required parameter.
    test "a missing token is invalid_request", %{conn: conn} do
      {client, _rt} = full_flow_refresh_token(conn)
      conn = post(build_conn(), "/oauth/revoke", %{"client_id" => client.client_id})
      assert json_response(conn, 400)["error"] == "invalid_request"
    end

    test "a non-string token is invalid_request, not a 500", %{conn: conn} do
      {client, _rt} = full_flow_refresh_token(conn)

      conn =
        post(build_conn(), "/oauth/revoke", %{"client_id" => client.client_id, "token" => ["x"]})

      assert json_response(conn, 400)["error"] == "invalid_request"
    end
  end

  describe "OAuth.cleanup_expired/0" do
    test "deletes authorization codes past expiry + grace" do
      user = insert(:user)

      {:ok, client} =
        OAuth.register_client(%{
          "redirect_uris" => ["https://x/cb"],
          "client_name" => "c"
        })

      {:ok, validated} =
        OAuth.validate_authorization_request(%{
          "client_id" => client.client_id,
          "redirect_uri" => hd(client.redirect_uris),
          "response_type" => "code",
          "code_challenge" => "abc",
          "code_challenge_method" => "S256"
        })

      {:ok, _} = OAuth.mint_authorization_code(user, validated, :all, nil)

      past = DateTime.utc_now(:second) |> DateTime.add(-86_400, :second)

      Repo.update_all(
        Engram.OAuth.AuthorizationCode,
        [set: [expires_at: past]],
        skip_tenant_check: true
      )

      assert {deleted, _} = OAuth.cleanup_expired()
      assert deleted >= 1
    end

    test "deletes refresh tokens revoked >7d ago" do
      {client, rt} = full_flow_refresh_token(build_conn())

      # Revoke + age out
      assert post(build_conn(), "/oauth/revoke", %{
               "token" => rt,
               "client_id" => client.client_id
             }).status == 200

      old = DateTime.utc_now(:second) |> DateTime.add(-30 * 24 * 3600, :second)

      Repo.update_all(
        from(r in RefreshToken, where: not is_nil(r.revoked_at)),
        [set: [revoked_at: old]],
        skip_tenant_check: true
      )

      assert {deleted, _} = OAuth.cleanup_expired()
      assert deleted >= 1
    end
  end
end
