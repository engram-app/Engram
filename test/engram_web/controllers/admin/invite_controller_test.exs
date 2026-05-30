defmodule EngramWeb.Admin.InviteControllerTest do
  use EngramWeb.ConnCase, async: false

  setup do
    Application.put_env(:engram, :auth_provider, :local)
    on_exit(fn -> Application.put_env(:engram, :auth_provider, :local) end)
    %{admin: insert(:user, role: "admin")}
  end

  test "POST creates an invite and returns the raw token once", %{conn: conn, admin: admin} do
    conn =
      conn
      |> authenticate(admin)
      |> post(~p"/api/admin/invites", %{label: "Mom", max_uses: 3, expires_in_days: 7})

    body = json_response(conn, 201)
    assert is_binary(body["token"])
    assert String.contains?(body["url"], body["token"])
    assert body["invite"]["label"] == "Mom"
    assert body["invite"]["max_uses"] == 3
  end

  test "GET lists active invites without exposing tokens", %{conn: conn, admin: admin} do
    {:ok, _} = Engram.Invites.create_invite(admin, %{label: "x"})
    conn = conn |> authenticate(admin) |> get(~p"/api/admin/invites")
    [row | _] = json_response(conn, 200)["invites"]
    assert row["label"] == "x"
    refute Map.has_key?(row, "token")
    refute Map.has_key?(row, "token_hash")
  end

  test "DELETE revokes an invite", %{conn: conn, admin: admin} do
    {:ok, {_raw, invite}} = Engram.Invites.create_invite(admin, %{})
    conn = conn |> authenticate(admin) |> delete(~p"/api/admin/invites/#{invite.id}")
    assert json_response(conn, 200)["ok"] == true
    assert Engram.Invites.list_active() == []
  end
end
