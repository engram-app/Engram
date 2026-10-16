defmodule EngramWeb.OAuthAudienceTest do
  @moduledoc """
  Audience-bound OAuth access tokens (RFC 8707, MCP 2025-11-25 "Token
  Handling", #1977).

  A token minted at `/oauth/token` is for the MCP server. It works at
  `/api/mcp`, and on `POST /api/attachments` because the
  `get_attachment_upload_target` tool tells the client to upload there with
  the same token. Everywhere else, REST and the sync socket, it is refused, so
  a token leaked from a connector's logs no longer reaches notes CRUD.

  Device-flow tokens (the Obsidian plugin) and every token minted before this
  change carry the legacy `aud`, and keep working exactly as before.

  """
  use EngramWeb.ConnCase, async: false

  alias Engram.Accounts
  alias Engram.OAuth

  require Phoenix.ChannelTest

  @endpoint EngramWeb.Endpoint
  @redirect "https://claude.ai/api/mcp/auth_callback"

  setup do
    EngramWeb.RateLimiter.reset_buckets!()
    user = :user |> insert() |> ensure_external_id()
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "V", Ecto.UUID.generate())
    lift_api_rps_cap!(user)
    %{user: user, vault: vault}
  end

  # The real exchange, so the claim under test is the one /oauth/token mints.
  defp oauth_access_token(user, extra \\ %{}) do
    {:ok, client} = OAuth.register_client(%{"redirect_uris" => [@redirect], "client_name" => "C"})
    {verifier, challenge} = Engram.OAuthHelpers.pkce_pair()

    {:ok, validated} =
      OAuth.validate_authorization_request(
        Map.merge(
          %{
            "client_id" => client.client_id,
            "redirect_uri" => @redirect,
            "response_type" => "code",
            "code_challenge" => challenge,
            "code_challenge_method" => "S256"
          },
          extra
        )
      )

    {:ok, url} = OAuth.mint_authorization_code(user, validated, :all, nil)

    build_conn()
    |> post("/oauth/token", %{
      "grant_type" => "authorization_code",
      "code" => Engram.OAuthHelpers.code_from_redirect(url),
      "redirect_uri" => @redirect,
      "client_id" => client.client_id,
      "code_verifier" => verifier
    })
    |> json_response(200)
    |> Map.fetch!("access_token")
  end

  defp bearer(token), do: put_req_header(build_conn(), "authorization", "Bearer #{token}")

  test "an OAuth access token names the MCP audience", %{user: user} do
    assert {:ok, %{"aud" => "engram:mcp"}} = Accounts.verify_jwt(oauth_access_token(user))
  end

  test "it works on /api/mcp", %{user: user} do
    body =
      user
      |> oauth_access_token()
      |> bearer()
      |> post("/api/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
      |> json_response(200)

    assert [_ | _] = body["result"]["tools"]
  end

  test "it is refused on REST with invalid_token", %{user: user} do
    conn = user |> oauth_access_token() |> bearer() |> get("/api/vaults")

    assert json_response(conn, 401)
    assert [challenge] = get_resp_header(conn, "www-authenticate")
    assert challenge =~ ~s(error="invalid_token")
  end

  # The upload tool's documented contract: same token, POST /api/attachments.
  test "it is accepted for attachment upload", %{user: user, vault: vault} do
    conn =
      user
      |> oauth_access_token()
      |> bearer()
      |> put_req_header("x-vault-id", vault.id)
      |> post("/api/attachments", %{"path" => "a.txt", "content_base64" => Base.encode64("hi")})

    assert conn.status in 200..299, conn.resp_body
  end

  test "it is refused on the sync socket", %{user: user} do
    assert :error =
             Phoenix.ChannelTest.connect(EngramWeb.UserSocket, %{
               "token" => oauth_access_token(user)
             })
  end

  test "a legacy-audience token keeps working on REST", %{user: user} do
    legacy = Accounts.generate_jwt(user, %{"scope" => "mcp"})

    assert legacy
           |> bearer()
           |> get("/api/vaults")
           |> json_response(200)
  end

  describe "resource indicator (RFC 8707 §2)" do
    test "our own resource is accepted, on any of our spellings", %{user: user} do
      for resource <- [
            EngramWeb.Endpoint.url() <> "/api/mcp",
            EngramWeb.Endpoint.url() <> "/api/mcp/",
            EngramWeb.Endpoint.url(),
            # RFC 3986 §6.2.2.1: the host is case-insensitive.
            String.upcase(EngramWeb.Endpoint.url()) <> "/api/mcp",
            # OAuth 2.1 §3.1: empty is absent.
            ""
          ] do
        assert is_binary(oauth_access_token(user, %{"resource" => resource})), resource
      end
    end

    test "a foreign resource is refused with invalid_target", %{user: _user} do
      {:ok, client} =
        OAuth.register_client(%{"redirect_uris" => [@redirect], "client_name" => "C"})

      {_verifier, challenge} = Engram.OAuthHelpers.pkce_pair()

      [location] =
        build_conn()
        |> get("/oauth/authorize", %{
          "client_id" => client.client_id,
          "redirect_uri" => @redirect,
          "response_type" => "code",
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "state" => "s",
          "resource" => "https://other-mcp.example/mcp"
        })
        |> get_resp_header("location")

      query = URI.decode_query(URI.parse(location).query)
      assert String.starts_with?(location, @redirect)
      assert query["error"] == "invalid_target"
      assert query["state"] == "s"
    end
  end

  # Repeated `resource[]=` values, all ours: validated, not forwarded, no 500.
  test "a list of our own resources at authorize reaches consent" do
    {:ok, client} = OAuth.register_client(%{"redirect_uris" => [@redirect], "client_name" => "C"})
    {_verifier, challenge} = Engram.OAuthHelpers.pkce_pair()
    ours = EngramWeb.Endpoint.url() <> "/api/mcp"

    conn =
      get(build_conn(), "/oauth/authorize", %{
        "client_id" => client.client_id,
        "redirect_uri" => @redirect,
        "response_type" => "code",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "resource" => [ours, ours]
      })

    assert [location] = get_resp_header(conn, "location")
    assert location =~ "/oauth/consent?"
  end

  # Client authentication runs first, so a stranger cannot pin an
  # invalid_target on a vendor's client_id.
  test "a foreign resource with failed client auth is invalid_client" do
    conn =
      post(build_conn(), "/oauth/token", %{
        "grant_type" => "authorization_code",
        "code" => "x",
        "client_id" => Ecto.UUID.generate(),
        "code_verifier" => "v",
        "resource" => "https://other-mcp.example/mcp"
      })

    assert json_response(conn, 401)["error"] == "invalid_client"
  end

  # RFC 8707 §2.2: the token request may name the resource too.
  test "a foreign resource at the token endpoint is invalid_target", %{user: user} do
    {:ok, client} = OAuth.register_client(%{"redirect_uris" => [@redirect], "client_name" => "C"})
    {verifier, challenge} = Engram.OAuthHelpers.pkce_pair()

    {:ok, validated} =
      OAuth.validate_authorization_request(%{
        "client_id" => client.client_id,
        "redirect_uri" => @redirect,
        "response_type" => "code",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256"
      })

    {:ok, url} = OAuth.mint_authorization_code(user, validated, :all, nil)

    conn =
      post(build_conn(), "/oauth/token", %{
        "grant_type" => "authorization_code",
        "code" => Engram.OAuthHelpers.code_from_redirect(url),
        "redirect_uri" => @redirect,
        "client_id" => client.client_id,
        "code_verifier" => verifier,
        "resource" => "https://other-mcp.example/mcp"
      })

    assert json_response(conn, 400)["error"] == "invalid_target"
  end

  # RFC 6750 §3.1 / OAuth 2.1 §5.2: a valid token without the scope the
  # resource needs is 403 insufficient_scope, naming the scope.
  test "an MCP-audience token without the mcp scope is insufficient_scope", %{user: user} do
    token = Accounts.generate_jwt(user, %{"aud" => "engram:mcp", "scope" => "other"})

    conn =
      token
      |> bearer()
      |> post("/api/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

    assert conn.status == 403
    assert [challenge] = get_resp_header(conn, "www-authenticate")
    assert challenge =~ ~s(error="insufficient_scope")
    assert challenge =~ ~s(scope="mcp")
    # MCP 2025-11-25: the same pointer the 401 carries.
    assert challenge =~ ~s(resource_metadata=")
  end
end
