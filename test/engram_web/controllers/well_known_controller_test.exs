defmodule EngramWeb.WellKnownControllerTest do
  use EngramWeb.ConnCase, async: true

  describe "GET /.well-known/oauth-protected-resource" do
    test "returns RFC 9728 protected resource metadata", %{conn: conn} do
      conn = get(conn, "/.well-known/oauth-protected-resource")
      body = json_response(conn, 200)

      assert is_binary(body["resource"])
      # No host_rewrite config in plain test conn (selfhost shape) → MCP is only
      # at the /api/mcp path, so that's the advertised resource. The bare-host
      # form is mcp_host-only; see WellKnownHostTest.
      assert String.ends_with?(body["resource"], "/api/mcp")
      assert is_list(body["authorization_servers"])
      assert body["authorization_servers"] != []
      assert Enum.all?(body["authorization_servers"], &is_binary/1)
    end

    test "advertises bearer token usage", %{conn: conn} do
      conn = get(conn, "/.well-known/oauth-protected-resource")
      body = json_response(conn, 200)

      assert "header" in body["bearer_methods_supported"]
    end

    test "responds with application/json content-type", %{conn: conn} do
      conn = get(conn, "/.well-known/oauth-protected-resource")

      assert ["application/json" <> _] = get_resp_header(conn, "content-type")
    end
  end

  describe "GET /.well-known/oauth-authorization-server" do
    test "returns RFC 8414 server metadata with required fields", %{conn: conn} do
      conn = get(conn, "/.well-known/oauth-authorization-server")
      body = json_response(conn, 200)

      assert is_binary(body["issuer"])
      assert String.ends_with?(body["authorization_endpoint"], "/oauth/authorize")
      assert String.ends_with?(body["token_endpoint"], "/oauth/token")
      assert String.ends_with?(body["registration_endpoint"], "/oauth/register")
      assert String.ends_with?(body["revocation_endpoint"], "/oauth/revoke")
    end

    test "requires PKCE S256 (no plain)", %{conn: conn} do
      conn = get(conn, "/.well-known/oauth-authorization-server")
      body = json_response(conn, 200)

      assert "S256" in body["code_challenge_methods_supported"]
      refute "plain" in body["code_challenge_methods_supported"]
    end

    test "advertises authorization_code + refresh_token grants", %{conn: conn} do
      conn = get(conn, "/.well-known/oauth-authorization-server")
      body = json_response(conn, 200)

      assert "authorization_code" in body["grant_types_supported"]
      assert "refresh_token" in body["grant_types_supported"]
    end

    test "advertises code response type", %{conn: conn} do
      conn = get(conn, "/.well-known/oauth-authorization-server")
      body = json_response(conn, 200)

      assert "code" in body["response_types_supported"]
    end

    test "advertises mcp scope", %{conn: conn} do
      conn = get(conn, "/.well-known/oauth-authorization-server")
      body = json_response(conn, 200)

      assert "mcp" in body["scopes_supported"]
    end

    test "advertises only public PKCE (none) — no confidential auth methods", %{
      conn: conn
    } do
      conn = get(conn, "/.well-known/oauth-authorization-server")
      body = json_response(conn, 200)

      # Must match what /oauth/register actually accepts (#282) — advertising
      # client_secret_* here would tell clients to request a method we 400 on.
      assert body["token_endpoint_auth_methods_supported"] == ["none"]
    end

    test "responds with application/json content-type", %{conn: conn} do
      conn = get(conn, "/.well-known/oauth-authorization-server")

      assert ["application/json" <> _] = get_resp_header(conn, "content-type")
    end
  end
end
