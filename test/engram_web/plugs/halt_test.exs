defmodule EngramWeb.Plugs.HaltTest do
  use EngramWeb.ConnCase, async: true

  alias EngramWeb.Plugs.Halt

  test "sends the encoded body with the given status and halts", %{conn: conn} do
    conn = Halt.json(conn, 402, %{error: "nope", upgrade_url: "/x"})

    assert conn.halted
    assert conn.status == 402
    assert json_response(conn, 402) == %{"error" => "nope", "upgrade_url" => "/x"}
  end

  test "sets the charset-qualified JSON content type", %{conn: conn} do
    # Pins the wire contract shared with Phoenix.Controller.json — both emit
    # `application/json; charset=utf-8`, which is what let the Controller.json
    # call sites (AccountLifecycle, AccountDeleted) convert to this helper
    # without a byte of response drift.
    conn = Halt.json(conn, 401, %{error: "unauthorized"})

    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
  end

  test "preserves response headers put before the call", %{conn: conn} do
    # RotationLockCheck / PreAuthRateLimit set Retry-After etc. before
    # delegating; the helper must not clobber them.
    conn =
      conn
      |> put_resp_header("retry-after", "60")
      |> Halt.json(503, %{error: "rotation_in_progress"})

    assert get_resp_header(conn, "retry-after") == ["60"]
  end
end
