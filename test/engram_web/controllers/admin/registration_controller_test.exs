defmodule EngramWeb.Admin.RegistrationControllerTest do
  use EngramWeb.ConnCase, async: false

  setup do
    Application.put_env(:engram, :auth_provider, :local)
    on_exit(fn -> Application.put_env(:engram, :auth_provider, :local) end)
    :ok
  end

  test "GET shows current mode for an admin", %{conn: conn} do
    admin = insert(:user, role: "admin")
    conn = conn |> authenticate(admin) |> get(~p"/api/admin/registration")
    assert json_response(conn, 200)["registration_mode"] in ~w(closed invite_only open)
  end

  test "PATCH updates the mode", %{conn: conn} do
    admin = insert(:user, role: "admin")
    conn = conn |> authenticate(admin) |> patch(~p"/api/admin/registration", %{mode: "open"})
    assert json_response(conn, 200)["registration_mode"] == "open"
    assert Engram.Instance.registration_mode() == "open"
  end

  test "PATCH rejects an invalid mode with 422", %{conn: conn} do
    admin = insert(:user, role: "admin")
    conn = conn |> authenticate(admin) |> patch(~p"/api/admin/registration", %{mode: "nope"})
    assert json_response(conn, 422)["error"] == "invalid_mode"
  end

  test "non-admin gets 403", %{conn: conn} do
    member = insert(:user, role: "member")
    conn = conn |> authenticate(member) |> get(~p"/api/admin/registration")
    assert json_response(conn, 403)
  end
end
