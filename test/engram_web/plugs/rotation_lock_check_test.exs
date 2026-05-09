defmodule EngramWeb.Plugs.RotationLockCheckTest do
  use EngramWeb.ConnCase, async: true

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
end
