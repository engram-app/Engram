defmodule EngramWeb.OAuthRevokeControllerTest do
  use EngramWeb.ConnCase, async: false

  import Ecto.Query

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

  defp pkce_pair do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  defp full_flow_refresh_token(conn) do
    user = insert(:user)

    {:ok, client} =
      OAuth.register_client(%{
        "redirect_uris" => ["https://x/cb"],
        "client_name" => "x"
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

    {:ok, redirect_url} = OAuth.mint_authorization_code(user, validated, "vault:*")
    code = URI.parse(redirect_url).query |> URI.decode_query() |> Map.fetch!("code")

    %{"refresh_token" => rt} =
      json_response(
        post(conn, "/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => redirect_uri,
          "client_id" => client.client_id,
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

    test "force-disconnects live sockets for the token's owner", %{conn: conn} do
      {client, rt} = full_flow_refresh_token(conn)
      hash = :crypto.hash(:sha256, rt) |> Base.encode16(case: :lower)

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
      conn =
        post(conn, "/oauth/revoke", %{
          "token" => "engram_oauth_rt_doesnotexist",
          "client_id" => "00000000-0000-0000-0000-000000000000"
        })

      assert conn.status == 200
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

    test "responds 200 with missing token", %{conn: conn} do
      conn = post(conn, "/oauth/revoke", %{"client_id" => "x"})
      assert conn.status == 200
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

      {:ok, _} = OAuth.mint_authorization_code(user, validated, "vault:*")

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
