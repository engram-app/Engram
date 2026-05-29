defmodule EngramWeb.Plugs.RequireAdminTest do
  use EngramWeb.ConnCase, async: false
  alias EngramWeb.Plugs.RequireAdmin
  alias Engram.Accounts.User

  setup do
    Application.put_env(:engram, :auth_provider, :local)
    on_exit(fn -> Application.put_env(:engram, :auth_provider, :local) end)
    :ok
  end

  defp call(conn), do: RequireAdmin.call(conn, [])

  test "passes an admin user through", %{conn: conn} do
    conn = assign(conn, :current_user, %User{role: "admin", suspended_at: nil})
    refute call(conn).halted
  end

  test "rejects a member with 403", %{conn: conn} do
    conn = conn |> assign(:current_user, %User{role: "member", suspended_at: nil}) |> call()
    assert conn.halted and conn.status == 403
  end

  test "rejects a suspended admin with 403", %{conn: conn} do
    conn =
      conn
      |> assign(:current_user, %User{role: "admin", suspended_at: ~U[2026-01-01 00:00:00Z]})
      |> call()

    assert conn.status == 403
  end

  test "returns 404 under clerk auth (feature hidden)", %{conn: conn} do
    Application.put_env(:engram, :auth_provider, :clerk)
    conn = conn |> assign(:current_user, %User{role: "admin", suspended_at: nil}) |> call()
    assert conn.halted and conn.status == 404
  end
end
