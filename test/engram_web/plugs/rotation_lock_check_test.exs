defmodule EngramWeb.Plugs.RotationLockCheckTest do
  use EngramWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  alias EngramWeb.Plugs.RotationLockCheck
  alias Engram.Accounts.User

  test "passes through when current_user has no lock", %{conn: conn} do
    user = %User{id: 1, dek_rotation_locked_at: nil}
    conn = conn |> assign(:current_user, user) |> RotationLockCheck.call([])
    refute conn.halted
    refute conn.status == 503
  end

  test "halts with 503 + Retry-After when current_user is locked", %{conn: conn} do
    user = %User{id: 1, dek_rotation_locked_at: DateTime.utc_now()}
    conn = conn |> assign(:current_user, user) |> RotationLockCheck.call([])
    assert conn.halted
    assert conn.status == 503
    assert ["60"] = Plug.Conn.get_resp_header(conn, "retry-after")
    body = Phoenix.ConnTest.json_response(conn, 503)
    assert body["error"] == "rotation_in_progress"
  end

  test "passes through when no current_user assigned (let auth plugs decide)", %{conn: conn} do
    conn = RotationLockCheck.call(conn, [])
    refute conn.halted
  end

  describe "router pipeline integration" do
    setup do
      user = insert(:user)
      _vault = insert(:vault, user: user, is_default: true)
      {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")

      Engram.Repo.update_all(
        from(u in Engram.Accounts.User, where: u.id == ^user.id),
        set: [dek_rotation_locked_at: DateTime.utc_now()]
      )

      user = Engram.Repo.reload!(user)
      {:ok, user: user, api_key: api_key}
    end

    @tag :integration
    test "GET /api/me returns 503 when user is rotation-locked", %{conn: conn, user: _user, api_key: api_key} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{api_key}")
        |> get("/api/me")

      assert conn.status == 503
      assert ["60"] = Plug.Conn.get_resp_header(conn, "retry-after")
    end

    @tag :integration
    test "GET /api/folders/list returns 503 when user is rotation-locked", %{conn: conn, user: _user, api_key: api_key} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{api_key}")
        |> get("/api/folders/list")

      assert conn.status == 503
    end
  end
end
