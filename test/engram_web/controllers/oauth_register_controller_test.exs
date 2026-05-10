defmodule EngramWeb.OAuthRegisterControllerTest do
  use EngramWeb.ConnCase, async: false

  setup_all do
    on_exit(fn ->
      Application.put_env(:engram, :rate_limit_override, 10_000)
    end)

    :ok
  end

  setup do
    Hammer.delete_buckets("/oauth/register:127.0.0.1")
    Application.put_env(:engram, :rate_limit_override, 10_000)
    :ok
  end

  describe "POST /oauth/register — happy path" do
    test "registers a public client with PKCE", %{conn: conn} do
      params = %{
        "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"],
        "client_name" => "Claude",
        "scope" => "mcp"
      }

      conn = post(conn, "/oauth/register", params)
      body = json_response(conn, 201)

      assert is_binary(body["client_id"])
      assert byte_size(body["client_id"]) > 0
      assert body["redirect_uris"] == params["redirect_uris"]
      assert body["client_name"] == "Claude"
      assert body["token_endpoint_auth_method"] == "none"
      assert is_integer(body["client_id_issued_at"])
      assert "authorization_code" in body["grant_types"]
      assert "refresh_token" in body["grant_types"]
      assert body["response_types"] == ["code"]
      # Public client → no secret returned
      refute Map.has_key?(body, "client_secret")
    end

    test "accepts loopback http redirect_uri", %{conn: conn} do
      params = %{
        "redirect_uris" => ["http://localhost:9999/cb", "http://127.0.0.1:9999/cb"],
        "client_name" => "local-cli"
      }

      conn = post(conn, "/oauth/register", params)
      body = json_response(conn, 201)

      assert "http://localhost:9999/cb" in body["redirect_uris"]
      assert "http://127.0.0.1:9999/cb" in body["redirect_uris"]
    end

    test "accepts native-app custom scheme redirect_uri", %{conn: conn} do
      params = %{
        "redirect_uris" => ["com.cursor.app://oauth/callback"],
        "client_name" => "Cursor"
      }

      conn = post(conn, "/oauth/register", params)
      body = json_response(conn, 201)

      assert "com.cursor.app://oauth/callback" in body["redirect_uris"]
    end

    test "persists the client", %{conn: conn} do
      conn1 =
        post(conn, "/oauth/register", %{
          "redirect_uris" => ["https://example.com/cb"],
          "client_name" => "test"
        })

      body = json_response(conn1, 201)
      client_id = body["client_id"]

      assert {:ok, client} = Engram.OAuth.get_client(client_id)
      assert client.client_name == "test"
      assert client.redirect_uris == ["https://example.com/cb"]
    end
  end

  describe "POST /oauth/register — invalid input" do
    test "rejects empty redirect_uris", %{conn: conn} do
      conn = post(conn, "/oauth/register", %{"redirect_uris" => []})
      body = json_response(conn, 400)

      assert body["error"] == "invalid_redirect_uri"
    end

    test "rejects missing redirect_uris", %{conn: conn} do
      conn = post(conn, "/oauth/register", %{"client_name" => "x"})
      body = json_response(conn, 400)

      assert body["error"] == "invalid_redirect_uri"
    end

    test "rejects http redirect_uri to non-loopback host", %{conn: conn} do
      conn =
        post(conn, "/oauth/register", %{
          "redirect_uris" => ["http://example.com/cb"]
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_redirect_uri"
    end

    test "rejects javascript: redirect_uri", %{conn: conn} do
      conn =
        post(conn, "/oauth/register", %{
          "redirect_uris" => ["javascript:alert(1)"]
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_redirect_uri"
    end

    test "rejects unsupported grant_type", %{conn: conn} do
      conn =
        post(conn, "/oauth/register", %{
          "redirect_uris" => ["https://x/cb"],
          "grant_types" => ["password"]
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_client_metadata"
    end
  end

  describe "POST /oauth/register — rate limit" do
    test "returns 429 after 10 registrations from same IP in a minute", %{conn: conn} do
      Application.put_env(:engram, :rate_limit_override, 10)
      Hammer.delete_buckets("/oauth/register:127.0.0.1")

      for _ <- 1..10 do
        post(conn, "/oauth/register", %{"redirect_uris" => ["https://x/cb"]})
      end

      conn = post(conn, "/oauth/register", %{"redirect_uris" => ["https://x/cb"]})
      assert conn.status == 429
    end
  end
end
