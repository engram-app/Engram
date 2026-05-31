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

  # ──────────────────────────────────────────────────────────────────
  # GET /oauth/authorize — Phase 7.A: now PUBLIC (browser navigation,
  # no Bearer header on 302). Validates request, then 302s to the SPA
  # at /oauth/consent?<all-params>. Invalid client/redirect still
  # returns 400 HTML (no redirect — code-leak prevention).
  # ──────────────────────────────────────────────────────────────────

  describe "GET /oauth/authorize — happy path (PUBLIC, no auth required)" do
    test "redirects to /oauth/consent with all params preserved", %{conn: conn} do
      client = register_client()
      redirect_uri = hd(client.redirect_uris)
      params = valid_params(client.client_id, redirect_uri)

      conn = get(conn, "/oauth/authorize", params)

      assert conn.status == 302
      [location] = get_resp_header(conn, "location")

      uri = URI.parse(location)
      assert uri.path == "/oauth/consent"

      query = URI.decode_query(uri.query)
      assert query["client_id"] == client.client_id
      assert query["redirect_uri"] == redirect_uri
      assert query["response_type"] == "code"
      assert query["code_challenge"] == "abc123challenge"
      assert query["code_challenge_method"] == "S256"
      assert query["state"] == "xyz"
      assert query["scope"] == "mcp"
    end

    test "preserves resource param (RFC 8707) pass-through", %{conn: conn} do
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params =
        client.client_id
        |> valid_params(redirect_uri)
        |> Map.put("resource", "https://app.engram.page/api/mcp")

      conn = get(conn, "/oauth/authorize", params)

      assert conn.status == 302
      [location] = get_resp_header(conn, "location")
      query = location |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      assert query["resource"] == "https://app.engram.page/api/mcp"
    end

    test "does NOT require Authorization: Bearer header", %{conn: conn} do
      client = register_client()
      redirect_uri = hd(client.redirect_uris)
      params = valid_params(client.client_id, redirect_uri)

      conn = get(conn, "/oauth/authorize", params)

      refute conn.status == 401
      assert conn.status == 302
    end
  end

  describe "GET /oauth/authorize — invalid client" do
    test "returns 400 HTML when client_id is unknown", %{conn: conn} do
      params = valid_params("00000000-0000-0000-0000-000000000000", "https://x/cb")

      conn = get(conn, "/oauth/authorize", params)

      assert conn.status == 400
      assert conn.resp_body =~ "invalid_client"
    end

    test "returns 400 HTML when redirect_uri does not match registration", %{conn: conn} do
      client = register_client("https://claude.ai/api/mcp/auth_callback")

      params = valid_params(client.client_id, "https://attacker.example/cb")

      conn = get(conn, "/oauth/authorize", params)

      assert conn.status == 400
      assert conn.resp_body =~ "invalid_redirect_uri"
    end
  end

  describe "GET /oauth/authorize — bad params (redirect with error)" do
    test "redirects to redirect_uri?error=unsupported_response_type when not code", %{conn: conn} do
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params =
        client.client_id
        |> valid_params(redirect_uri)
        |> Map.put("response_type", "token")

      conn = get(conn, "/oauth/authorize", params)

      assert conn.status == 302
      [location] = get_resp_header(conn, "location")
      assert String.starts_with?(location, redirect_uri)
      assert location =~ "error=unsupported_response_type"
      assert location =~ "state=xyz"
    end

    test "redirects with invalid_request when code_challenge missing", %{conn: conn} do
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params =
        client.client_id
        |> valid_params(redirect_uri)
        |> Map.delete("code_challenge")

      conn = get(conn, "/oauth/authorize", params)

      assert conn.status == 302
      [location] = get_resp_header(conn, "location")
      assert location =~ "error=invalid_request"
    end

    test "redirects with invalid_request when code_challenge_method is plain", %{conn: conn} do
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params =
        client.client_id
        |> valid_params(redirect_uri)
        |> Map.put("code_challenge_method", "plain")

      conn = get(conn, "/oauth/authorize", params)

      assert conn.status == 302
      [location] = get_resp_header(conn, "location")
      assert location =~ "error=invalid_request"
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # POST /api/oauth/authorize/consent — Phase 7.A: SPA submits this
  # with the user's Bearer JWT after the consent UI is approved.
  # Returns JSON {redirect_uri: "..."} so the SPA can window.location.
  # ──────────────────────────────────────────────────────────────────

  describe "POST /api/oauth/authorize/consent — auth required" do
    test "returns 401 when no Authorization header is present", %{conn: conn} do
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params =
        client.client_id
        |> valid_params(redirect_uri)
        |> Map.put("vault_choice", "vault:*")

      conn = post(conn, "/api/oauth/authorize/consent", params)
      assert conn.status == 401
    end
  end

  describe "POST /api/oauth/authorize/consent — happy path" do
    test "mints a code and returns JSON redirect_uri with code + state", %{conn: conn} do
      user = insert(:user)
      vault = insert(:vault, user: user)
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params =
        client.client_id
        |> valid_params(redirect_uri)
        |> Map.put("vault_choice", "vault:#{vault.id}")

      conn = conn |> jwt_authed(user) |> post("/api/oauth/authorize/consent", params)

      assert conn.status == 200
      json = Jason.decode!(conn.resp_body)
      assert is_binary(json["redirect_uri"])
      assert String.starts_with?(json["redirect_uri"], redirect_uri)

      uri = URI.parse(json["redirect_uri"])
      query = URI.decode_query(uri.query)
      assert query["state"] == "xyz"
      assert is_binary(query["code"]) and byte_size(query["code"]) > 16

      assert {:ok, code_row} = OAuth.get_authorization_code_by_raw(query["code"])
      assert code_row.user_id == user.id
      assert code_row.client_id == client.client_id
      assert code_row.vault_id == vault.id
      assert code_row.scope == "mcp"
    end

    test "mints code with vault_id=nil when vault_choice=vault:*", %{conn: conn} do
      user = insert(:user)
      _vault = insert(:vault, user: user)
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params =
        client.client_id
        |> valid_params(redirect_uri)
        |> Map.put("vault_choice", "vault:*")

      conn = conn |> jwt_authed(user) |> post("/api/oauth/authorize/consent", params)

      assert conn.status == 200
      json = Jason.decode!(conn.resp_body)
      uri = URI.parse(json["redirect_uri"])
      query = URI.decode_query(uri.query)

      assert {:ok, code_row} = OAuth.get_authorization_code_by_raw(query["code"])
      assert is_nil(code_row.vault_id)
    end
  end

  describe "POST /api/oauth/authorize/consent — vault ownership" do
    test "returns 200 with redirect_uri carrying ?error=access_denied when vault not owned",
         %{conn: conn} do
      user = insert(:user)
      other = insert(:user)
      other_vault = insert(:vault, user: other)
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params =
        client.client_id
        |> valid_params(redirect_uri)
        |> Map.put("vault_choice", "vault:#{other_vault.id}")

      conn = conn |> jwt_authed(user) |> post("/api/oauth/authorize/consent", params)

      assert conn.status == 200
      json = Jason.decode!(conn.resp_body)
      assert String.starts_with?(json["redirect_uri"], redirect_uri)
      assert json["redirect_uri"] =~ "error=access_denied"
      assert json["redirect_uri"] =~ "state=xyz"
    end
  end

  describe "POST /api/oauth/authorize/consent — invalid request" do
    test "invalid client_id returns 400 JSON (no redirect — code-leak prevention)", %{conn: conn} do
      user = insert(:user)

      params =
        valid_params("00000000-0000-0000-0000-000000000000", "https://x/cb")
        |> Map.put("vault_choice", "vault:*")

      conn = conn |> jwt_authed(user) |> post("/api/oauth/authorize/consent", params)

      assert conn.status == 400
      json = Jason.decode!(conn.resp_body)
      # EnforceConnectionCap fires before the controller and rejects unknown
      # client_ids with this error code. The 400 code-leak-prevention guarantee
      # still holds — we never redirect an unknown client.
      assert json["error"] == "missing_or_invalid_client_id"
    end

    test "missing code_challenge returns redirect_uri with error in JSON", %{conn: conn} do
      user = insert(:user)
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params =
        client.client_id
        |> valid_params(redirect_uri)
        |> Map.delete("code_challenge")
        |> Map.put("vault_choice", "vault:*")

      conn = conn |> jwt_authed(user) |> post("/api/oauth/authorize/consent", params)

      assert conn.status == 200
      json = Jason.decode!(conn.resp_body)
      assert String.starts_with?(json["redirect_uri"], redirect_uri)
      assert json["redirect_uri"] =~ "error=invalid_request"
    end
  end

  # ──────────────────────────────────────────────────────────────────
  # POST /oauth/authorize — RETIRED in Phase 7.A. The SPA uses
  # /api/oauth/authorize/consent with Bearer JWT instead.
  # ──────────────────────────────────────────────────────────────────

  describe "POST /oauth/authorize — retired" do
    test "old route no longer matches (returns 404)", %{conn: conn} do
      client = register_client()
      redirect_uri = hd(client.redirect_uris)

      params =
        client.client_id
        |> valid_params(redirect_uri)
        |> Map.put("vault_choice", "vault:*")

      conn = post(conn, "/oauth/authorize", params)
      assert conn.status == 404
    end
  end
end
