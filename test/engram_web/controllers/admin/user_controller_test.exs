defmodule EngramWeb.Admin.UserControllerTest do
  use EngramWeb.ConnCase, async: false
  use Oban.Testing, repo: Engram.Repo

  setup do
    Application.put_env(:engram, :auth_provider, :local)
    on_exit(fn -> Application.put_env(:engram, :auth_provider, :local) end)
    %{admin: insert(:user, role: "admin")}
  end

  test "GET lists users", %{conn: conn, admin: admin} do
    _m = insert(:user, role: "member")
    conn = conn |> authenticate(admin) |> get(~p"/api/admin/users")
    assert length(json_response(conn, 200)["users"]) >= 2
  end

  test "PATCH promotes a member to admin", %{conn: conn, admin: admin} do
    m = insert(:user, role: "member")
    conn = conn |> authenticate(admin) |> patch(~p"/api/admin/users/#{m.id}", %{role: "admin"})
    assert json_response(conn, 200)["user"]["role"] == "admin"
  end

  test "PATCH demoting last admin returns 409", %{conn: conn, admin: admin} do
    conn =
      conn |> authenticate(admin) |> patch(~p"/api/admin/users/#{admin.id}", %{role: "member"})

    assert json_response(conn, 409)["error"] == "last_admin"
  end

  test "PATCH suspends a member", %{conn: conn, admin: admin} do
    m = insert(:user, role: "member")
    conn = conn |> authenticate(admin) |> patch(~p"/api/admin/users/#{m.id}", %{suspended: true})
    assert json_response(conn, 200)["user"]["suspended"] == true
  end

  test "DELETE soft-deletes a member and enqueues vault purge", %{conn: conn, admin: admin} do
    m = insert(:user, role: "member")
    vault = insert(:vault, user: m)

    conn = conn |> authenticate(admin) |> delete(~p"/api/admin/users/#{m.id}")
    assert json_response(conn, 200)["ok"] == true

    # Spec §7: backend actually purges the data, not just the user row.
    assert_enqueued(
      worker: Engram.Workers.CleanupVault,
      args: %{vault_id: vault.id, user_id: m.id, force: true}
    )
  end

  test "DELETE last admin returns 409", %{conn: conn, admin: admin} do
    conn = conn |> authenticate(admin) |> delete(~p"/api/admin/users/#{admin.id}")
    assert json_response(conn, 409)["error"] == "last_admin"
  end

  test "POST password-reset stub returns 501 until D3", %{conn: conn, admin: admin} do
    m = insert(:user, role: "member")
    conn = conn |> authenticate(admin) |> post(~p"/api/admin/users/#{m.id}/password-reset")
    assert json_response(conn, 501)["error"] == "not_implemented"
  end
end
