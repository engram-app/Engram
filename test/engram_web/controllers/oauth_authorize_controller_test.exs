defmodule EngramWeb.OAuthAuthorizeControllerTest do
  use EngramWeb.ConnCase, async: true

  alias Engram.OAuth
  alias Engram.Repo

  defp jwt_authed(conn, user) do
    user = ensure_external_id(user)
    {:ok, token} = Engram.Auth.Providers.Local.issue_access_token(user.external_id, user.email)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp ensure_external_id(%{external_id: ext} = user) when is_binary(ext) and ext != "", do: user

  defp ensure_external_id(user) do
    {:ok, updated} =
      user
      |> Ecto.Changeset.change(external_id: "test-#{user.id}")
      |> Repo.update(skip_tenant_check: true)

    updated
  end

  defp register_client(redirect_uri \\ "https://claude.ai/api/mcp/auth_callback") do
    {:ok, client} =
      OAuth.register_client(%{
        "redirect_uris" => [redirect_uri],
        "client_name" => "Claude"
      })

    client
  end

  defp valid_params(client_id, redirect_uri) do
    %{
      "client_id" => client_id,
      "redirect_uri" => redirect_uri,
      "response_type" => "code",
      "code_challenge" => "abc123challenge",
      "code_challenge_method" => "S256",
      "state" => "xyz",
      "scope" => "mcp"
    }
  end

  describe "GET /oauth/authorize — unauthenticated" do
    test "returns 401 when no Authorization header is present", %{conn: conn} do
      client = register_client()
      params = valid_params(client.client_id, hd(client.redirect_uris))

      conn = get(conn, "/oauth/authorize", params)
      assert conn.status == 401
    end
  end

  describe "GET /oauth/authorize — invalid client" do
    test "returns 400 HTML when client_id is unknown", %{conn: conn} do
      user = insert(:user)

      params =
        valid_params("00000000-0000-0000-0000-000000000000", "https://x/cb")

      conn = conn |> jwt_authed(user) |> get("/oauth/authorize", params)

      assert conn.status == 400
      assert conn.resp_body =~ "invalid_client"
    end

    test "returns 400 HTML when redirect_uri does not match registration", %{conn: conn} do
      user = insert(:user)
      client = register_client("https://claude.ai/api/mcp/auth_callback")

      params = valid_params(client.client_id, "https://attacker.example/cb")

      conn = conn |> jwt_authed(user) |> get("/oauth/authorize", params)

      assert conn.status == 400
      assert conn.resp_body =~ "invalid_redirect_uri"
    end
  end

  describe "GET /oauth/authorize — bad params (redirect with error)" do
    test "redirects to redirect_uri?error=unsupported_response_type when not code", %{conn: conn} do
      user = insert(:user)
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params =
        client.client_id
        |> valid_params(redirect_uri)
        |> Map.put("response_type", "token")

      conn = conn |> jwt_authed(user) |> get("/oauth/authorize", params)

      assert conn.status == 302
      [location] = get_resp_header(conn, "location")
      assert String.starts_with?(location, redirect_uri)
      assert location =~ "error=unsupported_response_type"
      assert location =~ "state=xyz"
    end

    test "redirects with invalid_request when code_challenge missing", %{conn: conn} do
      user = insert(:user)
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params =
        client.client_id
        |> valid_params(redirect_uri)
        |> Map.delete("code_challenge")

      conn = conn |> jwt_authed(user) |> get("/oauth/authorize", params)

      assert conn.status == 302
      [location] = get_resp_header(conn, "location")
      assert location =~ "error=invalid_request"
    end

    test "redirects with invalid_request when code_challenge_method is plain", %{conn: conn} do
      user = insert(:user)
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params =
        client.client_id
        |> valid_params(redirect_uri)
        |> Map.put("code_challenge_method", "plain")

      conn = conn |> jwt_authed(user) |> get("/oauth/authorize", params)

      assert conn.status == 302
      [location] = get_resp_header(conn, "location")
      assert location =~ "error=invalid_request"
    end
  end

  describe "GET /oauth/authorize — happy path" do
    test "renders consent page with client name and vault picker", %{conn: conn} do
      user = insert(:user)
      _vault = insert(:vault, user: user, slug: "personal")
      client = register_client()
      params = valid_params(client.client_id, hd(client.redirect_uris))

      conn = conn |> jwt_authed(user) |> get("/oauth/authorize", params)

      assert html_response(conn, 200)
      assert conn.resp_body =~ "Claude"
      assert conn.resp_body =~ "personal"
      assert conn.resp_body =~ "All vaults"
      assert conn.resp_body =~ ~s(action="/oauth/authorize")
      assert conn.resp_body =~ ~s(method="post")
    end
  end

  describe "POST /oauth/authorize — happy path" do
    test "mints a code and redirects to redirect_uri with code + state", %{conn: conn} do
      user = insert(:user)
      vault = insert(:vault, user: user)
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params =
        client.client_id
        |> valid_params(redirect_uri)
        |> Map.put("vault_choice", "vault:#{vault.id}")

      conn = conn |> jwt_authed(user) |> post("/oauth/authorize", params)

      assert conn.status == 302
      [location] = get_resp_header(conn, "location")
      assert String.starts_with?(location, redirect_uri)

      uri = URI.parse(location)
      query = URI.decode_query(uri.query)
      assert query["state"] == "xyz"
      assert is_binary(query["code"]) and byte_size(query["code"]) > 16

      # Code persisted
      assert {:ok, code_row} = OAuth.get_authorization_code_by_raw(query["code"])
      assert code_row.user_id == user.id
      assert code_row.client_id == client.client_id
      assert code_row.vault_id == vault.id
      assert code_row.scope == "mcp"
    end

    test "mints a code with vault_id=nil when vault_choice=all", %{conn: conn} do
      user = insert(:user)
      _vault = insert(:vault, user: user)
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params =
        client.client_id
        |> valid_params(redirect_uri)
        |> Map.put("vault_choice", "vault:*")

      conn = conn |> jwt_authed(user) |> post("/oauth/authorize", params)

      assert conn.status == 302
      [location] = get_resp_header(conn, "location")
      uri = URI.parse(location)
      query = URI.decode_query(uri.query)

      assert {:ok, code_row} = OAuth.get_authorization_code_by_raw(query["code"])
      assert is_nil(code_row.vault_id)
    end

    test "rejects vault_choice that does not belong to the user", %{conn: conn} do
      user = insert(:user)
      other = insert(:user)
      other_vault = insert(:vault, user: other)
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params =
        client.client_id
        |> valid_params(redirect_uri)
        |> Map.put("vault_choice", "vault:#{other_vault.id}")

      conn = conn |> jwt_authed(user) |> post("/oauth/authorize", params)

      assert conn.status == 302
      [location] = get_resp_header(conn, "location")
      assert location =~ "error=access_denied"
    end
  end

  describe "POST /oauth/authorize — unauthenticated" do
    test "returns 401 when no Authorization header is present", %{conn: conn} do
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params =
        client.client_id
        |> valid_params(redirect_uri)
        |> Map.put("vault_choice", "vault:*")

      conn = post(conn, "/oauth/authorize", params)
      assert conn.status == 401
    end
  end
end
