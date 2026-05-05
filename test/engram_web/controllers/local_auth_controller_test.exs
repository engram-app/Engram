defmodule EngramWeb.LocalAuthControllerTest do
  # async: false — tests mutate global Application config
  use EngramWeb.ConnCase, async: false

  setup do
    prev = Application.get_env(:engram, :auth_provider)
    Application.put_env(:engram, :auth_provider, :local)
    on_exit(fn -> Application.put_env(:engram, :auth_provider, prev || :local) end)
    :ok
  end

  describe "POST /api/auth/register" do
    test "creates user and returns access token + refresh cookie", %{conn: conn} do
      conn =
        post(conn, "/api/auth/register", %{email: "new@test.com", password: "StrongPass123!"})

      assert %{"access_token" => token, "user" => %{"email" => "new@test.com", "role" => "admin"}} =
               json_response(conn, 201)

      assert is_binary(token)
      cookie = conn.resp_cookies["refresh_token"]
      assert cookie
      assert cookie.http_only == true
      assert cookie.same_site == "Lax"
    end

    test "first user is admin, second is member", %{conn: conn} do
      post(conn, "/api/auth/register", %{email: "first@test.com", password: "StrongPass123!"})

      conn2 =
        post(build_conn(), "/api/auth/register", %{
          email: "second@test.com",
          password: "StrongPass123!"
        })

      assert %{"user" => %{"role" => "member"}} = json_response(conn2, 201)
    end

    test "rejects duplicate email with generic error", %{conn: conn} do
      post(conn, "/api/auth/register", %{email: "dup@test.com", password: "StrongPass123!"})

      conn2 =
        post(build_conn(), "/api/auth/register", %{
          email: "dup@test.com",
          password: "StrongPass123!"
        })

      assert %{"error" => "registration_failed"} = json_response(conn2, 422)
    end

    test "rejects short password with specific error", %{conn: conn} do
      conn = post(conn, "/api/auth/register", %{email: "short@test.com", password: "abc"})

      assert %{"error" => "password_too_short"} = json_response(conn, 422)
    end

    test "rejects password over 72 bytes", %{conn: conn} do
      conn =
        post(conn, "/api/auth/register", %{
          email: "long@test.com",
          password: String.duplicate("a", 73)
        })

      assert %{"error" => "password_too_long"} = json_response(conn, 422)
    end

    test "rejects missing fields", %{conn: conn} do
      conn = post(conn, "/api/auth/register", %{email: "no@pass.com"})

      assert %{"error" => "email and password required"} = json_response(conn, 422)
    end
  end

  describe "POST /api/auth/login" do
    setup %{conn: conn} do
      post(conn, "/api/auth/register", %{email: "login@test.com", password: "StrongPass123!"})
      :ok
    end

    test "returns access token + refresh cookie for valid credentials", %{conn: conn} do
      conn = post(conn, "/api/auth/login", %{email: "login@test.com", password: "StrongPass123!"})

      assert %{"access_token" => token} = json_response(conn, 200)
      assert is_binary(token)
      assert conn.resp_cookies["refresh_token"]
    end

    test "rejects wrong password with generic error", %{conn: conn} do
      conn = post(conn, "/api/auth/login", %{email: "login@test.com", password: "WrongPass!"})

      assert %{"error" => "invalid_credentials"} = json_response(conn, 401)
    end

    test "rejects nonexistent user with generic error", %{conn: conn} do
      conn = post(conn, "/api/auth/login", %{email: "nobody@test.com", password: "Whatever!"})

      assert %{"error" => "invalid_credentials"} = json_response(conn, 401)
    end
  end

  describe "POST /api/auth/refresh" do
    test "issues new access token from refresh cookie", %{conn: conn} do
      register_conn =
        post(conn, "/api/auth/register", %{email: "refresh@test.com", password: "StrongPass123!"})

      cookie = register_conn.resp_cookies["refresh_token"]

      conn2 =
        build_conn()
        |> put_req_cookie("refresh_token", cookie.value)
        |> post("/api/auth/refresh")

      assert %{"access_token" => new_token} = json_response(conn2, 200)
      assert is_binary(new_token)
      assert conn2.resp_cookies["refresh_token"]
      assert conn2.resp_cookies["refresh_token"].value != cookie.value
    end

    test "rejects missing cookie", %{conn: conn} do
      conn = post(conn, "/api/auth/refresh")

      assert %{"error" => "no_refresh_token"} = json_response(conn, 401)
    end
  end

  describe "POST /api/auth/logout" do
    test "clears refresh cookie", %{conn: conn} do
      register_conn =
        post(conn, "/api/auth/register", %{email: "logout@test.com", password: "StrongPass123!"})

      cookie = register_conn.resp_cookies["refresh_token"]

      conn2 =
        build_conn()
        |> put_req_cookie("refresh_token", cookie.value)
        |> post("/api/auth/logout")

      assert response(conn2, 204)
      assert conn2.resp_cookies["refresh_token"].max_age == 0
    end
  end

  describe "RequireLocalAuth plug" do
    test "returns 404 when auth_provider is clerk", %{conn: conn} do
      Application.put_env(:engram, :auth_provider, :clerk)

      conn =
        post(conn, "/api/auth/register", %{email: "blocked@test.com", password: "StrongPass123!"})

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end

    test "allows requests when auth_provider is local", %{conn: conn} do
      conn =
        post(conn, "/api/auth/register", %{email: "allowed@test.com", password: "StrongPass123!"})

      assert json_response(conn, 201)
    end
  end
end
