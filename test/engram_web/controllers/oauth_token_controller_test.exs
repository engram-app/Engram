defmodule EngramWeb.OAuthTokenControllerTest do
  use EngramWeb.ConnCase, async: true

  import Ecto.Query

  alias Engram.OAuth
  alias Engram.OAuth.RefreshToken
  alias Engram.Repo

  defp hash_token(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

  defp pkce_pair do
    verifier =
      :crypto.strong_rand_bytes(48)
      |> Base.url_encode64(padding: false)

    challenge =
      :crypto.hash(:sha256, verifier)
      |> Base.url_encode64(padding: false)

    {verifier, challenge}
  end

  defp register_client(redirect_uri \\ "https://claude.ai/api/mcp/auth_callback") do
    {:ok, client} =
      OAuth.register_client(%{
        "redirect_uris" => [redirect_uri],
        "client_name" => "Claude"
      })

    client
  end

  defp mint_code(user, client, redirect_uri, challenge, opts \\ []) do
    state = Keyword.get(opts, :state, "xyz")

    vault_choice =
      case Keyword.fetch(opts, :vault_ids) do
        {:ok, ids} -> ids
        :error -> Keyword.get(opts, :vault_choice, :all)
      end

    {:ok, validated} =
      OAuth.validate_authorization_request(%{
        "client_id" => client.client_id,
        "redirect_uri" => redirect_uri,
        "response_type" => "code",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "state" => state,
        "scope" => "mcp"
      })

    {:ok, redirect_url} = OAuth.mint_authorization_code(user, validated, vault_choice)

    %{query: query} = URI.parse(redirect_url)
    URI.decode_query(query)["code"]
  end

  describe "POST /oauth/token — authorization_code grant" do
    test "exchanges valid code for access + refresh tokens", %{conn: conn} do
      user = insert(:user)
      client = register_client()
      redirect_uri = hd(client.redirect_uris)
      {verifier, challenge} = pkce_pair()
      code = mint_code(user, client, redirect_uri, challenge)

      params = %{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => redirect_uri,
        "client_id" => client.client_id,
        "code_verifier" => verifier
      }

      conn = post(conn, "/oauth/token", params)
      body = json_response(conn, 200)

      assert is_binary(body["access_token"])
      assert is_binary(body["refresh_token"])
      assert String.starts_with?(body["refresh_token"], "engram_oauth_rt_")
      assert body["token_type"] == "Bearer"
      assert is_integer(body["expires_in"]) and body["expires_in"] > 0
      assert body["scope"] == "mcp"
    end

    test "rejects when code is unknown", %{conn: conn} do
      client = register_client()

      params = %{
        "grant_type" => "authorization_code",
        "code" => "engram_ac_doesnotexist",
        "redirect_uri" => hd(client.redirect_uris),
        "client_id" => client.client_id,
        "code_verifier" => "verifier"
      }

      conn = post(conn, "/oauth/token", params)
      body = json_response(conn, 400)

      assert body["error"] == "invalid_grant"
    end

    test "rejects code reuse (already consumed)", %{conn: conn} do
      user = insert(:user)
      client = register_client()
      redirect_uri = hd(client.redirect_uris)
      {verifier, challenge} = pkce_pair()
      code = mint_code(user, client, redirect_uri, challenge)

      params = %{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => redirect_uri,
        "client_id" => client.client_id,
        "code_verifier" => verifier
      }

      assert json_response(post(conn, "/oauth/token", params), 200)
      conn2 = post(build_conn(), "/oauth/token", params)
      body = json_response(conn2, 400)
      assert body["error"] == "invalid_grant"
    end

    test "rejects when code_verifier does not hash to code_challenge", %{conn: conn} do
      user = insert(:user)
      client = register_client()
      redirect_uri = hd(client.redirect_uris)
      {_verifier, challenge} = pkce_pair()
      code = mint_code(user, client, redirect_uri, challenge)

      params = %{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => redirect_uri,
        "client_id" => client.client_id,
        "code_verifier" => "wrong_verifier"
      }

      conn = post(conn, "/oauth/token", params)
      body = json_response(conn, 400)
      assert body["error"] == "invalid_grant"
    end

    test "rejects when redirect_uri does not match the one used at /authorize", %{conn: conn} do
      user = insert(:user)
      client = register_client()
      {verifier, challenge} = pkce_pair()
      code = mint_code(user, client, hd(client.redirect_uris), challenge)

      params = %{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => "https://attacker.example/cb",
        "client_id" => client.client_id,
        "code_verifier" => verifier
      }

      conn = post(conn, "/oauth/token", params)
      body = json_response(conn, 400)
      assert body["error"] == "invalid_grant"
    end

    test "rejects when client_id does not match the code's client_id", %{conn: conn} do
      user = insert(:user)
      client = register_client()
      redirect_uri = hd(client.redirect_uris)
      {verifier, challenge} = pkce_pair()
      code = mint_code(user, client, redirect_uri, challenge)

      other_client = register_client("https://other.example/cb")

      params = %{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => redirect_uri,
        "client_id" => other_client.client_id,
        "code_verifier" => verifier
      }

      conn = post(conn, "/oauth/token", params)
      body = json_response(conn, 400)
      assert body["error"] == "invalid_grant"
    end

    test "stamps last_used_at and last_used_ip on the newly-minted refresh token", %{conn: conn} do
      user = insert(:user)
      client = register_client()
      redirect_uri = hd(client.redirect_uris)
      {verifier, challenge} = pkce_pair()
      code = mint_code(user, client, redirect_uri, challenge)

      conn =
        post(conn, "/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => redirect_uri,
          "client_id" => client.client_id,
          "code_verifier" => verifier
        })

      body = json_response(conn, 200)
      token_hash = hash_token(body["refresh_token"])

      row =
        Repo.one!(
          from(rt in RefreshToken, where: rt.token_hash == ^token_hash),
          skip_tenant_check: true
        )

      assert row.last_used_at != nil
      assert is_binary(row.last_used_ip)
      assert row.last_used_ip =~ ~r/^\d+\.\d+\.\d+\.\d+$|^[0-9a-fA-F:]+$/
    end

    test "rejects expired code", %{conn: conn} do
      user = insert(:user)
      client = register_client()
      redirect_uri = hd(client.redirect_uris)
      {verifier, challenge} = pkce_pair()
      code = mint_code(user, client, redirect_uri, challenge)

      # Force-expire the row
      {:ok, row} = OAuth.get_authorization_code_by_raw(code)

      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      row
      |> Ecto.Changeset.change(%{expires_at: past})
      |> Repo.update!(skip_tenant_check: true)

      params = %{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => redirect_uri,
        "client_id" => client.client_id,
        "code_verifier" => verifier
      }

      conn = post(conn, "/oauth/token", params)
      body = json_response(conn, 400)
      assert body["error"] == "invalid_grant"
    end

    test "a multi-vault grant round-trips vault_ids through exchange and refresh",
         %{conn: conn} do
      user = insert(:user)
      a = insert(:vault, user: user, slug: "tok-a")
      b = insert(:vault, user: user, slug: "tok-b")
      client = register_client()
      redirect_uri = hd(client.redirect_uris)
      {verifier, challenge} = pkce_pair()

      code = mint_code(user, client, redirect_uri, challenge, vault_ids: [a.id, b.id])

      body =
        conn
        |> post("/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => redirect_uri,
          "client_id" => client.client_id,
          "code_verifier" => verifier
        })
        |> json_response(200)

      {:ok, claims} = Engram.Accounts.verify_jwt(body["access_token"])
      assert Enum.sort(claims["vault_ids"]) == Enum.sort([a.id, b.id])
      # No single id means "A and B" — must not claim a scalar binding.
      refute Map.has_key?(claims, "vault_id")

      refreshed =
        build_conn()
        |> post("/oauth/token", %{
          "grant_type" => "refresh_token",
          "refresh_token" => body["refresh_token"],
          "client_id" => client.client_id
        })
        |> json_response(200)

      {:ok, claims2} = Engram.Accounts.verify_jwt(refreshed["access_token"])
      assert Enum.sort(claims2["vault_ids"]) == Enum.sort([a.id, b.id])
    end

    test "a legacy refresh token with only vault_id still mints a scoped access token",
         %{conn: conn} do
      user = insert(:user)
      a = insert(:vault, user: user, slug: "tok-legacy")
      client = register_client()
      redirect_uri = hd(client.redirect_uris)
      {verifier, challenge} = pkce_pair()

      code = mint_code(user, client, redirect_uri, challenge, vault_ids: [a.id])

      body =
        conn
        |> post("/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => redirect_uri,
          "client_id" => client.client_id,
          "code_verifier" => verifier
        })
        |> json_response(200)

      # Simulate a row written before this release: scalar set, array NULL.
      Engram.Repo.update_all(
        Engram.OAuth.RefreshToken,
        [set: [vault_ids: nil]], skip_tenant_check: true)

      refreshed =
        build_conn()
        |> post("/oauth/token", %{
          "grant_type" => "refresh_token",
          "refresh_token" => body["refresh_token"],
          "client_id" => client.client_id
        })
        |> json_response(200)

      {:ok, claims} = Engram.Accounts.verify_jwt(refreshed["access_token"])
      assert claims["vault_ids"] == [a.id]
    end
  end

  describe "POST /oauth/token — refresh_token grant" do
    test "rotates refresh token and issues new access token", %{conn: conn} do
      user = insert(:user)
      client = register_client()
      redirect_uri = hd(client.redirect_uris)
      {verifier, challenge} = pkce_pair()
      code = mint_code(user, client, redirect_uri, challenge)

      conn1 =
        post(conn, "/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => redirect_uri,
          "client_id" => client.client_id,
          "code_verifier" => verifier
        })

      %{"refresh_token" => first_refresh, "access_token" => first_access} =
        json_response(conn1, 200)

      conn2 =
        post(build_conn(), "/oauth/token", %{
          "grant_type" => "refresh_token",
          "refresh_token" => first_refresh,
          "client_id" => client.client_id
        })

      body = json_response(conn2, 200)

      assert is_binary(body["access_token"])
      assert is_binary(body["refresh_token"])
      assert body["refresh_token"] != first_refresh
      assert body["access_token"] != first_access
    end

    test "rejects reused refresh token (already rotated)", %{conn: conn} do
      user = insert(:user)
      client = register_client()
      redirect_uri = hd(client.redirect_uris)
      {verifier, challenge} = pkce_pair()
      code = mint_code(user, client, redirect_uri, challenge)

      %{"refresh_token" => first_refresh} =
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

      # Use it once → rotates
      assert json_response(
               post(build_conn(), "/oauth/token", %{
                 "grant_type" => "refresh_token",
                 "refresh_token" => first_refresh,
                 "client_id" => client.client_id
               }),
               200
             )

      # Reuse → reject
      conn2 =
        post(build_conn(), "/oauth/token", %{
          "grant_type" => "refresh_token",
          "refresh_token" => first_refresh,
          "client_id" => client.client_id
        })

      body = json_response(conn2, 400)
      assert body["error"] == "invalid_grant"
    end

    test "revokes whole family on detected reuse (RFC 6749 §10.4)", %{conn: conn} do
      user = insert(:user)
      client = register_client()
      redirect_uri = hd(client.redirect_uris)
      {verifier, challenge} = pkce_pair()
      code = mint_code(user, client, redirect_uri, challenge)

      %{"refresh_token" => rt1} =
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

      # Rotate rt1 → rt2
      %{"refresh_token" => rt2} =
        json_response(
          post(build_conn(), "/oauth/token", %{
            "grant_type" => "refresh_token",
            "refresh_token" => rt1,
            "client_id" => client.client_id
          }),
          200
        )

      # Replay rt1 → must reject AND invalidate rt2 (whole family burned)
      assert json_response(
               post(build_conn(), "/oauth/token", %{
                 "grant_type" => "refresh_token",
                 "refresh_token" => rt1,
                 "client_id" => client.client_id
               }),
               400
             )

      # rt2 must now be rejected too
      assert json_response(
               post(build_conn(), "/oauth/token", %{
                 "grant_type" => "refresh_token",
                 "refresh_token" => rt2,
                 "client_id" => client.client_id
               }),
               400
             )
    end

    test "stamps last_used_at and last_used_ip on the new refresh token after rotation", %{
      conn: conn
    } do
      user = insert(:user)
      client = register_client()
      redirect_uri = hd(client.redirect_uris)
      {verifier, challenge} = pkce_pair()
      code = mint_code(user, client, redirect_uri, challenge)

      %{"refresh_token" => first_refresh} =
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

      conn2 =
        post(build_conn(), "/oauth/token", %{
          "grant_type" => "refresh_token",
          "refresh_token" => first_refresh,
          "client_id" => client.client_id
        })

      body = json_response(conn2, 200)
      new_token_hash = hash_token(body["refresh_token"])

      new_row =
        Repo.one!(
          from(rt in RefreshToken,
            where: rt.token_hash == ^new_token_hash and is_nil(rt.consumed_at)
          ),
          skip_tenant_check: true
        )

      assert new_row.last_used_at != nil
      assert is_binary(new_row.last_used_ip)
      assert new_row.last_used_ip =~ ~r/^\d+\.\d+\.\d+\.\d+$|^[0-9a-fA-F:]+$/
    end

    test "rejects refresh token for a different client", %{conn: conn} do
      user = insert(:user)
      client = register_client()
      redirect_uri = hd(client.redirect_uris)
      {verifier, challenge} = pkce_pair()
      code = mint_code(user, client, redirect_uri, challenge)

      %{"refresh_token" => first_refresh} =
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

      other = register_client("https://other.example/cb")

      conn2 =
        post(build_conn(), "/oauth/token", %{
          "grant_type" => "refresh_token",
          "refresh_token" => first_refresh,
          "client_id" => other.client_id
        })

      body = json_response(conn2, 400)
      assert body["error"] == "invalid_grant"
    end
  end

  describe "POST /oauth/token — confidential client authentication" do
    defp confidential_client(method, redirect_uri) do
      {:ok, client} =
        OAuth.register_client(%{
          "redirect_uris" => [redirect_uri],
          "client_name" => "LobeChat",
          "token_endpoint_auth_method" => method
        })

      client
    end

    defp code_for(client, redirect_uri) do
      user = insert(:user)
      {verifier, challenge} = pkce_pair()
      {mint_code(user, client, redirect_uri, challenge), verifier}
    end

    test "exchanges a code when the secret arrives in the body", %{conn: conn} do
      uri = "https://app.lobehub.com/oauth/callback"
      client = confidential_client("client_secret_post", uri)
      {code, verifier} = code_for(client, uri)

      conn =
        post(conn, "/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => uri,
          "client_id" => client.client_id,
          "client_secret" => client.client_secret,
          "code_verifier" => verifier
        })

      assert %{"access_token" => token} = json_response(conn, 200)
      assert is_binary(token)
    end

    test "exchanges a code when the secret arrives via HTTP Basic", %{conn: conn} do
      uri = "https://app.lobehub.com/oauth/callback"
      client = confidential_client("client_secret_basic", uri)
      {code, verifier} = code_for(client, uri)

      basic = Base.encode64("#{client.client_id}:#{client.client_secret}")

      conn =
        conn
        |> put_req_header("authorization", "Basic #{basic}")
        |> post("/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => uri,
          "client_id" => client.client_id,
          "code_verifier" => verifier
        })

      assert %{"access_token" => _} = json_response(conn, 200)
    end

    test "rejects a confidential client that omits its secret", %{conn: conn} do
      uri = "https://app.lobehub.com/oauth/callback"
      client = confidential_client("client_secret_post", uri)
      {code, verifier} = code_for(client, uri)

      conn =
        post(conn, "/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => uri,
          "client_id" => client.client_id,
          "code_verifier" => verifier
        })

      assert %{"error" => "invalid_client"} = json_response(conn, 401)
    end

    test "rejects a wrong secret", %{conn: conn} do
      uri = "https://app.lobehub.com/oauth/callback"
      client = confidential_client("client_secret_post", uri)
      {code, verifier} = code_for(client, uri)

      conn =
        post(conn, "/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => uri,
          "client_id" => client.client_id,
          "client_secret" => "not-the-secret",
          "code_verifier" => verifier
        })

      assert %{"error" => "invalid_client"} = json_response(conn, 401)
    end

    # The registered method binds in BOTH directions. A public client that
    # starts presenting a secret is either confused or an attacker probing;
    # silently accepting it would make the registered method decorative.
    test "rejects a secret presented by a client registered public", %{conn: conn} do
      uri = "https://claude.ai/api/mcp/auth_callback"
      client = register_client(uri)
      {code, verifier} = code_for(client, uri)

      conn =
        post(conn, "/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => uri,
          "client_id" => client.client_id,
          "client_secret" => "unexpected",
          "code_verifier" => verifier
        })

      assert %{"error" => "invalid_client"} = json_response(conn, 401)
    end

    # Some OAuth libraries send `Basic base64("client_id:")` for public clients.
    # An empty password is "no secret", not a presented credential; reading it
    # literally would reject a public client for authenticating.
    test "treats an empty Basic password as no credential", %{conn: conn} do
      uri = "https://claude.ai/api/mcp/auth_callback"
      client = register_client(uri)
      {code, verifier} = code_for(client, uri)

      basic = Base.encode64("#{client.client_id}:")

      conn =
        conn
        |> put_req_header("authorization", "Basic #{basic}")
        |> post("/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => uri,
          "code_verifier" => verifier
        })

      assert %{"access_token" => _} = json_response(conn, 200)
    end

    test "authenticates the refresh grant too", %{conn: conn} do
      uri = "https://app.lobehub.com/oauth/callback"
      client = confidential_client("client_secret_post", uri)
      {code, verifier} = code_for(client, uri)

      %{"refresh_token" => refresh} =
        conn
        |> post("/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => uri,
          "client_id" => client.client_id,
          "client_secret" => client.client_secret,
          "code_verifier" => verifier
        })
        |> json_response(200)

      unauthenticated =
        build_conn()
        |> post("/oauth/token", %{
          "grant_type" => "refresh_token",
          "refresh_token" => refresh,
          "client_id" => client.client_id
        })

      assert %{"error" => "invalid_client"} = json_response(unauthenticated, 401)

      authenticated =
        build_conn()
        |> post("/oauth/token", %{
          "grant_type" => "refresh_token",
          "refresh_token" => refresh,
          "client_id" => client.client_id,
          "client_secret" => client.client_secret
        })

      assert %{"access_token" => _} = json_response(authenticated, 200)
    end
  end

  describe "POST /oauth/token — invalid input" do
    test "rejects unsupported grant_type", %{conn: conn} do
      conn = post(conn, "/oauth/token", %{"grant_type" => "password"})
      body = json_response(conn, 400)
      assert body["error"] == "unsupported_grant_type"
    end

    test "rejects missing grant_type", %{conn: conn} do
      conn = post(conn, "/oauth/token", %{})
      body = json_response(conn, 400)
      assert body["error"] == "invalid_request"
    end
  end
end
