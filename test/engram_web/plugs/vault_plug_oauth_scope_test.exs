defmodule EngramWeb.VaultPlugOAuthScopeTest do
  use EngramWeb.ConnCase, async: true

  # An OAuth access token is an ordinary user JWT with extra claims, so before
  # this it authenticated against every vault-scoped REST route with no vault
  # filter at all — the grant was enforced on /api/mcp only.

  setup do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    granted = insert(:vault, user: user, slug: "granted", is_default: true)
    other = insert(:vault, user: user, slug: "other")
    %{user: user, granted: granted, other: other}
  end

  defp scoped(conn, user, vault_ids) do
    user = ensure_external_id(user)
    token = Engram.Accounts.generate_jwt(user, %{"scope" => "mcp", "vault_ids" => vault_ids})
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp ensure_external_id(%{external_id: ext} = user) when is_binary(ext) and ext != "", do: user

  defp ensure_external_id(user) do
    {:ok, updated} =
      user
      |> Ecto.Changeset.change(external_id: "test-#{user.id}")
      |> Engram.Repo.update(skip_tenant_check: true)

    updated
  end

  test "a granted vault passes", %{conn: conn, user: user, granted: granted} do
    conn =
      conn
      |> scoped(user, [granted.id])
      |> put_req_header("x-vault-id", granted.id)
      |> get("/api/folders")

    assert conn.status == 200
  end

  test "a vault outside the grant is 403", %{
    conn: conn,
    user: user,
    granted: granted,
    other: other
  } do
    conn =
      conn
      |> scoped(user, [granted.id])
      |> put_req_header("x-vault-id", other.id)
      |> get("/api/folders")

    assert conn.status == 403
  end

  test "the default-vault fallback is also gated", %{conn: conn, user: user, other: other} do
    # `granted` is the DEFAULT vault; a grant for `other` alone must not let a
    # header-less request fall back into the default.
    conn = conn |> scoped(user, [other.id]) |> get("/api/folders")
    assert conn.status == 403
  end

  test "an unscoped grant reaches every vault", %{conn: conn, user: user, other: other} do
    user = ensure_external_id(user)
    token = Engram.Accounts.generate_jwt(user)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("x-vault-id", other.id)
      |> get("/api/folders")

    assert conn.status == 200
  end
end
