defmodule EngramWeb.AuthControllerTest do
  use EngramWeb.ConnCase, async: true

  # API key management routes are session/JWT only — an API-key-authenticated
  # caller must not be able to enumerate, create, or revoke other API keys.
  # Tests here use an internal HS256 JWT (the same kind the device flow issues)
  # to authenticate, and assert API-key bearer auth is rejected with 403.

  # Issues a token via the local auth provider so it round-trips through
  # TokenResolver as a session JWT (not via the API-key code path). Requires
  # the user to have an external_id the provider can resolve back to.
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
      |> Engram.Repo.update(skip_tenant_check: true)

    updated
  end

  defp api_key_authed(conn, user) do
    {:ok, raw_key, _} = Engram.Accounts.create_api_key(user, "auth-test-key")
    grant_api_write!(user)
    put_req_header(conn, "authorization", "Bearer #{raw_key}")
  end

  # ---------------------------------------------------------------------------
  # POST /api-keys
  # ---------------------------------------------------------------------------

  describe "POST /api-keys" do
    setup %{conn: conn} do
      user = insert(:user)
      insert(:vault, user: user, is_default: true)
      %{conn: jwt_authed(conn, user), user: user}
    end

    test "creates an API key and returns raw key", %{conn: conn} do
      conn = post(conn, "/api/api-keys", %{name: "my-new-key"})

      assert %{"key" => key, "name" => name, "id" => id} = json_response(conn, 200)
      assert String.starts_with?(key, "engram_")
      assert name == "my-new-key"
      assert is_integer(id)
    end

    test "created key can authenticate vault-scoped requests", %{conn: conn, user: user} do
      %{"key" => new_key} =
        conn
        |> post("/api/api-keys", %{name: "usable-key"})
        |> json_response(200)

      # Newly-minted API keys for Free users hit api_rps_cap=0 — grant the
      # paid-tier overrides so this test exercises the auth flow, not the
      # gate.
      grant_api_write!(user)

      conn2 =
        build_conn()
        |> put_req_header("authorization", "Bearer #{new_key}")
        |> get("/api/me")

      assert json_response(conn2, 200)
    end

    test "returns 401 without auth", %{conn: conn} do
      conn =
        conn
        |> delete_req_header("authorization")
        |> post("/api/api-keys", %{name: "nope"})

      assert json_response(conn, 401)
    end

    test "rejects API-key auth with 403", %{user: user} do
      conn =
        build_conn()
        |> api_key_authed(user)
        |> post("/api/api-keys", %{name: "should-not-be-created"})

      assert %{"error" => "api_key_not_allowed"} = json_response(conn, 403)
    end
  end

  describe "GET /api-keys" do
    setup %{conn: conn} do
      user = insert(:user)
      insert(:vault, user: user, is_default: true)
      {:ok, _raw, _} = Engram.Accounts.create_api_key(user, "setup-key")
      grant_api_write!(user)
      %{conn: jwt_authed(conn, user), user: user}
    end

    test "lists keys belonging to the current user", %{conn: conn, user: user} do
      {:ok, _, _} = Engram.Accounts.create_api_key(user, "second-key")
      grant_api_write!(user)

      conn = get(conn, "/api/api-keys")
      assert %{"keys" => keys} = json_response(conn, 200)
      assert length(keys) == 2

      names = Enum.map(keys, & &1["name"])
      assert "setup-key" in names
      assert "second-key" in names

      key = hd(keys)
      assert Map.has_key?(key, "id")
      assert Map.has_key?(key, "created_at")
      assert Map.has_key?(key, "last_used")
      refute Map.has_key?(key, "key_hash")
      refute Map.has_key?(key, "key")
    end

    test "does not return keys from other users", %{conn: conn} do
      other = insert(:user)
      {:ok, _, _} = Engram.Accounts.create_api_key(other, "other-key")
      grant_api_write!(other)

      conn = get(conn, "/api/api-keys")
      %{"keys" => keys} = json_response(conn, 200)
      names = Enum.map(keys, & &1["name"])
      refute "other-key" in names
    end

    test "returns 401 without auth", %{conn: conn} do
      conn =
        conn
        |> delete_req_header("authorization")
        |> get("/api/api-keys")

      assert json_response(conn, 401)
    end

    test "rejects API-key auth with 403 — prevents credential enumeration", %{user: user} do
      conn =
        build_conn()
        |> api_key_authed(user)
        |> get("/api/api-keys")

      assert %{"error" => "api_key_not_allowed"} = json_response(conn, 403)
    end
  end

  describe "DELETE /api-keys/:id" do
    setup %{conn: conn} do
      user = insert(:user)
      insert(:vault, user: user, is_default: true)
      {:ok, _raw, target_key} = Engram.Accounts.create_api_key(user, "to-be-revoked")
      grant_api_write!(user)
      %{conn: jwt_authed(conn, user), user: user, target_key_id: target_key.id}
    end

    test "returns 400 for non-integer API key id", %{conn: conn} do
      conn = delete(conn, "/api/api-keys/abc")
      assert %{"error" => _} = json_response(conn, 400)
    end

    test "rejects API-key auth with 403 — prevents revoking sibling keys", %{
      user: user,
      target_key_id: id
    } do
      conn =
        build_conn()
        |> api_key_authed(user)
        |> delete("/api/api-keys/#{id}")

      assert %{"error" => "api_key_not_allowed"} = json_response(conn, 403)
    end
  end
end
