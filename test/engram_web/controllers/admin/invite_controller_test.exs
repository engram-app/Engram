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
    # The path must match the frontend route exactly — `/sign-up`, not
    # `/signup`. Caught after a hand-test 404 on a copied invite link.
    assert body["url"] =~ ~r{/sign-up\?invite=}
    assert body["invite"]["label"] == "Mom"
    assert body["invite"]["max_uses"] == 3
  end

  # Same reasoning as the admin password-reset link: an invite URL carries a
  # live token and is handed to a human, so it must not inherit `conn.scheme`
  # (:http behind an edge that terminates TLS) or `conn.host` (a backend host
  # that may serve no SPA).
  test "the invite link is absolute against the canonical URL, not the dialed host",
       %{conn: conn, admin: admin} do
    body =
      %{conn | host: "api.engram.page", scheme: :http}
      |> authenticate(admin)
      |> post(~p"/api/admin/invites", %{label: "Mom"})
      |> json_response(201)

    assert body["url"] == EngramWeb.Endpoint.url() <> "/sign-up?invite=#{body["token"]}"
    refute body["url"] =~ "api.engram.page"
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

  test "DELETE returns 404 for an unknown invite id", %{conn: conn, admin: admin} do
    conn = conn |> authenticate(admin) |> delete(~p"/api/admin/invites/#{Ecto.UUID.generate()}")
    assert json_response(conn, 404) == %{"error" => "not_found"}
  end
end
