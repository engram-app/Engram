defmodule EngramWeb.Admin.DelegatedCredentialTest do
  @moduledoc """
  Admin routes are first-party-session only.

  `RequireAdmin` checks WHO the user is, not HOW they authenticated. Without
  `RequireSession` on the admin pipeline, any API key or OAuth grant an admin
  ever issued (plugin, script, MCP client) inherits the whole admin plane —
  including `POST /users/:id/password-reset`, which returns a raw reset token
  for ANY user: account takeover from a leaked delegated credential.
  """
  use EngramWeb.ConnCase, async: false

  setup %{conn: conn} do
    Application.put_env(:engram, :auth_provider, :local)
    on_exit(fn -> Application.put_env(:engram, :auth_provider, :local) end)

    admin = ensure_external_id(insert(:user, role: "admin"))
    victim = insert(:user, role: "member")

    {:ok, conn: put_req_header(conn, "accept", "application/json"), admin: admin, victim: victim}
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp api_key(admin) do
    {:ok, raw_key, _} = Engram.Accounts.create_api_key(admin, "admin-script")
    raw_key
  end

  defp oauth_token(admin), do: Engram.Accounts.generate_jwt(admin, %{"scope" => "mcp"})

  test "an admin's API key cannot mint a password reset for another user", %{
    conn: conn,
    admin: admin,
    victim: victim
  } do
    conn =
      conn |> bearer(api_key(admin)) |> post(~p"/api/admin/users/#{victim.id}/password-reset")

    assert %{"error" => "api_key_not_allowed"} = json_response(conn, 403)
  end

  test "an admin's OAuth grant cannot mint a password reset for another user", %{
    conn: conn,
    admin: admin,
    victim: victim
  } do
    conn =
      conn |> bearer(oauth_token(admin)) |> post(~p"/api/admin/users/#{victim.id}/password-reset")

    assert %{"error" => "oauth_grant_not_allowed"} = json_response(conn, 403)
  end

  test "an admin's API key cannot promote a user", %{conn: conn, admin: admin, victim: victim} do
    conn =
      conn |> bearer(api_key(admin)) |> patch(~p"/api/admin/users/#{victim.id}", %{role: "admin"})

    assert %{"error" => "api_key_not_allowed"} = json_response(conn, 403)
    assert Engram.Repo.reload!(victim).role == "member"
  end

  test "an admin's API key cannot read the diagnostics matrix", %{conn: conn, admin: admin} do
    conn = conn |> bearer(api_key(admin)) |> get(~p"/api/health/diagnostics")

    assert %{"error" => "api_key_not_allowed"} = json_response(conn, 403)
  end

  # Over-block guard: self-host admins run on exactly this session token.
  test "an admin's first-party session still reaches the admin plane", %{
    conn: conn,
    admin: admin,
    victim: victim
  } do
    conn = conn |> authenticate(admin) |> post(~p"/api/admin/users/#{victim.id}/password-reset")

    assert %{"token" => token} = json_response(conn, 201)
    assert is_binary(token)
  end
end
