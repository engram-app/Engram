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

  describe "an API key restriction and an OAuth grant on one request" do
    # `Permissions.vault_scope/1` INTERSECTS the two credential restrictions.
    # Today a single `Authorization: Bearer` resolves to exactly one of them
    # (`Plugs.Auth` sets `:current_api_key` OR takes the `:internal_jwt`
    # branch), so this pairing is not reachable over the wire — the intersect
    # exists so that if it ever becomes reachable it fails CLOSED instead of
    # widening. That makes this the one scope rule with no live coverage, so
    # the key is assigned onto the conn directly while the real pipeline
    # (Auth -> OAuthScopeEnforce -> VaultPlug -> controller) runs unchanged.
    setup %{user: user, granted: granted, other: other} do
      # An API-key request is gated by `RequireApiRpsBudget` BEFORE it reaches
      # VaultPlug, and Free caps `api_rps_cap` at 0 — without this the request
      # 429s and never exercises the scope check at all.
      Engram.ApiEntitlementHelpers.grant_api_write!(user)
      {:ok, _raw, key} = Engram.Accounts.create_api_key(user, "restricted")
      %{key: key, both: [granted, other]}
    end

    defp restrict_key_to(key, vaults) do
      Engram.Repo.insert_all(
        "api_key_vaults",
        Enum.map(vaults, fn v ->
          %{api_key_id: Ecto.UUID.dump!(key.id), vault_id: Ecto.UUID.dump!(v.id)}
        end)
      )
    end

    defp with_key(conn, key), do: Plug.Conn.assign(conn, :current_api_key, key)

    test "a vault in BOTH restrictions passes", %{
      conn: conn,
      user: user,
      granted: granted,
      key: key,
      both: both
    } do
      restrict_key_to(key, both)

      conn =
        conn
        |> with_key(key)
        |> scoped(user, [granted.id])
        |> put_req_header("x-vault-id", granted.id)
        |> get("/api/folders")

      assert conn.status == 200
    end

    test "a vault the KEY allows but the grant omits is 403", %{
      conn: conn,
      user: user,
      granted: granted,
      other: other,
      key: key,
      both: both
    } do
      restrict_key_to(key, both)

      conn =
        conn
        |> with_key(key)
        |> scoped(user, [granted.id])
        |> put_req_header("x-vault-id", other.id)
        |> get("/api/folders")

      assert conn.status == 403
    end

    test "a vault the GRANT allows but the key omits is 403", %{
      conn: conn,
      user: user,
      granted: granted,
      other: other,
      key: key
    } do
      # The union would be [granted, other] and this would pass. It must not.
      restrict_key_to(key, [granted])

      conn =
        conn
        |> with_key(key)
        |> scoped(user, [other.id])
        |> put_req_header("x-vault-id", other.id)
        |> get("/api/folders")

      assert conn.status == 403
    end

    test "disjoint restrictions reach nothing at all", %{
      conn: conn,
      user: user,
      granted: granted,
      other: other,
      key: key
    } do
      restrict_key_to(key, [granted])

      for vault <- [granted, other] do
        conn =
          conn
          |> with_key(key)
          |> scoped(user, [other.id])
          |> put_req_header("x-vault-id", vault.id)
          |> get("/api/folders")

        assert conn.status == 403
      end
    end
  end
end
