defmodule EngramWeb.OAuthRegisterControllerTest do
  use EngramWeb.ConnCase, async: false

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

    test "accepts multiple https redirect_uris", %{conn: conn} do
      uris = [
        "https://app.example.com/oauth/cb",
        "https://app.example.com/oauth/cb2",
        "https://other.example.com/cb"
      ]

      conn = post(conn, "/oauth/register", %{"redirect_uris" => uris})
      body = json_response(conn, 201)

      assert body["redirect_uris"] == uris
      assert {:ok, client} = Engram.OAuth.get_client(body["client_id"])
      assert client.redirect_uris == uris
    end

    test "persists software_id and software_version when provided", %{conn: conn} do
      conn =
        post(conn, "/oauth/register", %{
          "redirect_uris" => ["https://example.com/cb"],
          "client_name" => "Cursor",
          "software_id" => "com.cursor.app",
          "software_version" => "1.42.0"
        })

      body = json_response(conn, 201)

      assert {:ok, client} = Engram.OAuth.get_client(body["client_id"])
      assert client.software_id == "com.cursor.app"
      assert client.software_version == "1.42.0"
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

    test "rejects malformed JSON body with 400", %{conn: conn} do
      assert_error_sent(400, fn ->
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/oauth/register", "{not valid json")
      end)
    end

    test "rejects oversized body with 413", %{conn: conn} do
      # Endpoint's Plug.Parsers length cap is 11_000_000 bytes — push past it.
      oversized = String.duplicate("a", 11_000_001)

      assert_error_sent(413, fn ->
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/oauth/register", ~s({"redirect_uris":["https://x/cb"],"pad":"#{oversized}"}))
      end)
    end
  end

  describe "POST /oauth/register — impl gaps (#282)" do
    test "rejects non-array redirect_uris with 400, not a 500 crash", %{conn: conn} do
      conn = post(conn, "/oauth/register", %{"redirect_uris" => "https://x/cb"})
      body = json_response(conn, 400)

      assert body["error"] == "invalid_redirect_uri"
    end

    test "rejects client_secret_post auth method (only public PKCE supported)", %{conn: conn} do
      conn =
        post(conn, "/oauth/register", %{
          "redirect_uris" => ["https://x/cb"],
          "token_endpoint_auth_method" => "client_secret_post"
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_client_metadata"
    end

    test "rejects client_secret_basic auth method", %{conn: conn} do
      conn =
        post(conn, "/oauth/register", %{
          "redirect_uris" => ["https://x/cb"],
          "token_endpoint_auth_method" => "client_secret_basic"
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_client_metadata"
    end

    test "serializer echoes software_id and software_version", %{conn: conn} do
      conn =
        post(conn, "/oauth/register", %{
          "redirect_uris" => ["https://x/cb"],
          "client_name" => "Cursor",
          "software_id" => "com.cursor.app",
          "software_version" => "1.42.0"
        })

      body = json_response(conn, 201)
      assert body["software_id"] == "com.cursor.app"
      assert body["software_version"] == "1.42.0"
    end

    test "rejects overlong software_id", %{conn: conn} do
      conn =
        post(conn, "/oauth/register", %{
          "redirect_uris" => ["https://x/cb"],
          "software_id" => String.duplicate("a", 256)
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_client_metadata"
    end

    test "rejects overlong software_version", %{conn: conn} do
      conn =
        post(conn, "/oauth/register", %{
          "redirect_uris" => ["https://x/cb"],
          "software_version" => String.duplicate("a", 256)
        })

      body = json_response(conn, 400)
      assert body["error"] == "invalid_client_metadata"
    end

    test "emits dcr register telemetry on success", %{conn: conn} do
      ref =
        :telemetry_test.attach_event_handlers(self(), [[:engram, :mcp, :dcr, :register]])

      post(conn, "/oauth/register", %{
        "redirect_uris" => ["https://x/cb"],
        "software_id" => "com.cursor.app"
      })

      assert_received {[:engram, :mcp, :dcr, :register], ^ref, %{count: 1}, meta}
      assert meta.result == :ok
      assert is_binary(meta.client_id)
      assert meta.software_id == "com.cursor.app"

      :telemetry.detach(ref)
    end

    test "emits dcr register telemetry on error", %{conn: conn} do
      ref =
        :telemetry_test.attach_event_handlers(self(), [[:engram, :mcp, :dcr, :register]])

      post(conn, "/oauth/register", %{"redirect_uris" => []})

      assert_received {[:engram, :mcp, :dcr, :register], ^ref, %{count: 1}, %{result: :error}}

      :telemetry.detach(ref)
    end
  end

  describe "POST /oauth/register — rate limit" do
    test "returns 429 after 10 registrations from same IP in a minute", %{conn: conn} do
      Application.put_env(:engram, :rate_limit_override, 10)
      EngramWeb.RateLimiter.reset_buckets!()

      for _ <- 1..10 do
        post(conn, "/oauth/register", %{"redirect_uris" => ["https://x/cb"]})
      end

      conn = post(conn, "/oauth/register", %{"redirect_uris" => ["https://x/cb"]})
      assert conn.status == 429
    end
  end
end
