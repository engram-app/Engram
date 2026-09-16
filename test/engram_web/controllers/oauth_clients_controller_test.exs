defmodule EngramWeb.OAuthClientsControllerTest do
  use EngramWeb.ConnCase, async: true

  alias Engram.OAuth

  defp register_client(name \\ "Claude") do
    {:ok, client} =
      OAuth.register_client(%{
        "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"],
        "client_name" => name
      })

    client
  end

  defp register_client_at(name, redirect_uri) do
    {:ok, client} =
      OAuth.register_client(%{
        "redirect_uris" => [redirect_uri],
        "client_name" => name
      })

    client
  end

  describe "GET /api/oauth/clients/:client_id" do
    test "returns client_id + client_name only (no secret, no redirect_uris)", %{conn: conn} do
      client = register_client("My App")

      conn = get(conn, "/api/oauth/clients/#{client.client_id}")

      assert conn.status == 200
      json = Jason.decode!(conn.resp_body)

      assert json["client_id"] == client.client_id
      assert json["client_name"] == "My App"
      # `kind` is "mcp" for DCR-minted clients (the public endpoint rejects
      # "obsidian"); the consent page reads it to pick the right cap key.
      assert json["kind"] == "mcp"
      assert Map.keys(json) |> Enum.sort() == ["client_id", "client_name", "kind", "slug"]
    end

    test "does not require Authorization header (public endpoint)", %{conn: conn} do
      client = register_client()

      conn = get(conn, "/api/oauth/clients/#{client.client_id}")

      refute conn.status == 401
      assert conn.status == 200
    end

    test "returns 404 for unknown client_id (UUID-shaped)", %{conn: conn} do
      conn = get(conn, "/api/oauth/clients/00000000-0000-0000-0000-000000000000")

      assert conn.status == 404
      json = Jason.decode!(conn.resp_body)
      assert json["error"] == "not_found"
    end

    test "returns 404 for non-UUID client_id (no enumeration leak)", %{conn: conn} do
      conn = get(conn, "/api/oauth/clients/not-a-uuid")

      assert conn.status == 404
    end
  end

  describe "GET /api/oauth/clients/:client_id — slug" do
    test "resolves the catalog slug from the redirect the grant is using", %{conn: conn} do
      uri = "https://antigravity.google/oauth-callback"
      client = register_client_at("Google Antigravity", uri)

      conn = get(conn, "/api/oauth/clients/#{client.client_id}?redirect_uri=#{URI.encode(uri)}")

      assert Jason.decode!(conn.resp_body)["slug"] == "antigravity"
    end

    # The whole security property of `LogoAllowlist.resolve/4` is that the
    # redirect is the ONE the grant used. A query param is caller-supplied, so
    # honoring one the client never registered would let anyone name any
    # vendor host. Ignore it and fall back to what the record itself proves.
    test "ignores a redirect_uri the client has not registered", %{conn: conn} do
      client = register_client_at("Some App", "https://example.com/cb")

      conn =
        get(
          conn,
          "/api/oauth/clients/#{client.client_id}?redirect_uri=" <>
            URI.encode("https://antigravity.google/oauth-callback")
        )

      assert Jason.decode!(conn.resp_body)["slug"] == nil
    end

    # Loopback clients cannot be verified by host, so the catalog falls back to
    # the self-asserted name. That is not a security boundary (it sets `slug`
    # and nothing else) and it is the only thing that ticks a checklist row for
    # the whole local-first class.
    test "falls back to the client_name derivation for loopback redirects", %{conn: conn} do
      uri = "http://127.0.0.1:53682/callback"
      client = register_client_at("Claude Code (my-vault)", uri)

      conn = get(conn, "/api/oauth/clients/#{client.client_id}?redirect_uri=#{URI.encode(uri)}")

      assert Jason.decode!(conn.resp_body)["slug"] == "claude_code"
    end

    test "slug is null for a client we cannot attribute", %{conn: conn} do
      uri = "https://unknown-vendor.example/cb"
      client = register_client_at("Totally Unknown Thing", uri)

      conn = get(conn, "/api/oauth/clients/#{client.client_id}?redirect_uri=#{URI.encode(uri)}")

      assert Jason.decode!(conn.resp_body)["slug"] == nil
    end

    test "works with no redirect_uri param at all", %{conn: conn} do
      client =
        register_client_at("Google Antigravity", "https://antigravity.google/oauth-callback")

      conn = get(conn, "/api/oauth/clients/#{client.client_id}")

      assert conn.status == 200
      assert Map.has_key?(Jason.decode!(conn.resp_body), "slug")
    end
  end
end
