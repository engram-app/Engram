defmodule EngramWeb.PasswordControllerTest do
  use EngramWeb.ConnCase, async: false
  alias Engram.Accounts.PasswordReset

  setup do
    Application.put_env(:engram, :auth_provider, :local)
    on_exit(fn -> Application.put_env(:engram, :auth_provider, :local) end)
    :ok
  end

  defp seeded_member(pw) do
    {:ok, _} =
      Engram.Accounts.create_user_with_password(
        "admin#{System.unique_integer([:positive])}@x.com",
        "longpassword1"
      )

    {:ok, u} =
      Engram.Accounts.create_user_with_password(
        "u#{System.unique_integer([:positive])}@x.com",
        pw
      )

    u
  end

  test "POST /password/reset sets a new password with a valid token", %{conn: conn} do
    user = seeded_member("oldpassword1")
    admin = insert(:user, role: "admin")
    {:ok, {raw, _}} = PasswordReset.issue(user, admin)

    conn = post(conn, ~p"/api/auth/password/reset", %{token: raw, password: "newpassword2"})
    assert json_response(conn, 200)["ok"] == true
    assert {:ok, _} = Engram.Accounts.verify_password(user.email, "newpassword2")
  end

  test "POST /password/reset rejects a bad token", %{conn: conn} do
    conn = post(conn, ~p"/api/auth/password/reset", %{token: "garbage", password: "newpassword2"})
    assert json_response(conn, 422)["error"] == "invalid_token"
  end

  test "POST /password/change requires the correct old password", %{conn: conn} do
    user = seeded_member("oldpassword1")

    conn =
      conn
      |> authenticate(user)
      |> post(~p"/api/auth/password/change", %{
        old_password: "wrong",
        new_password: "newpassword2"
      })

    assert json_response(conn, 422)["error"] == "invalid_password"
  end

  test "POST /password/change works with the correct old password", %{conn: conn} do
    user = seeded_member("oldpassword1")

    conn =
      conn
      |> authenticate(user)
      |> post(~p"/api/auth/password/change", %{
        old_password: "oldpassword1",
        new_password: "newpassword2"
      })

    assert json_response(conn, 200)["ok"] == true
  end

  # Spec §8/§10 — a successful change revokes existing refresh tokens.
  test "POST /password/change revokes existing refresh tokens", %{conn: conn} do
    user = seeded_member("oldpassword1")
    {:ok, raw_refresh, _} = Engram.Accounts.create_refresh_token(user)

    conn =
      conn
      |> authenticate(user)
      |> post(~p"/api/auth/password/change", %{
        old_password: "oldpassword1",
        new_password: "newpassword2"
      })

    assert json_response(conn, 200)["ok"] == true
    assert {:error, _} = Engram.Accounts.consume_refresh_token(raw_refresh)
  end
end
