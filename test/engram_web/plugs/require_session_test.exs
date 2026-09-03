defmodule EngramWeb.Plugs.RequireSessionTest do
  @moduledoc """
  The credential-management boundary.

  These routes mint and revoke credentials, so reaching them with a DELEGATED
  credential is privilege escalation: an OAuth grant scoped to two vaults that
  can `POST /api-keys` has just issued itself an unrestricted one, escaping its
  own scope. The plug rejects API keys and OAuth grants alike, and must NOT
  reject an ordinary session (which is what self-host runs on).
  """
  use EngramWeb.ConnCase, async: false

  import Engram.Factory

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user)

    {:ok, conn: put_req_header(conn, "accept", "application/json"), user: user, vault: vault}
  end

  # An OAuth-issued access token: the same mint path `/oauth/token` uses, so the
  # `scope` claim this plug keys on is present exactly as it is in production.
  defp oauth_authed(conn, user, extras) do
    user = ensure_external_id(user)
    token = Engram.Accounts.generate_jwt(user, extras)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  # A first-party session token, minted the way the self-host SPA mints it.
  defp session_authed(conn, user) do
    user = ensure_external_id(user)
    {:ok, token} = Engram.Auth.Providers.Local.issue_access_token(user.external_id, user.email)
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

  describe "OAuth grants are blocked from credential management" do
    test "a vault-scoped grant cannot MINT an api key", %{conn: conn, user: user, vault: vault} do
      # THE escalation case. Without this the app walks away holding an
      # unrestricted credential it was never granted.
      conn =
        conn
        |> oauth_authed(user, %{"scope" => "mcp", "vault_ids" => [vault.id]})
        |> post("/api/api-keys", %{name: "escalated"})

      assert %{"error" => "oauth_grant_not_allowed"} = json_response(conn, 403)

      # And nothing was created as a side effect of the rejected request.
      assert Engram.Repo.all(Engram.Accounts.ApiKey, skip_tenant_check: true) == []
    end

    test "a vault-scoped grant cannot list connections", %{conn: conn, user: user, vault: vault} do
      conn =
        conn
        |> oauth_authed(user, %{"scope" => "mcp", "vault_ids" => [vault.id]})
        |> get("/api/connections")

      assert %{"error" => "oauth_grant_not_allowed"} = json_response(conn, 403)
    end

    test "an UNSCOPED (all-vaults) grant is blocked too", %{conn: conn, user: user} do
      # No vault_ids claim = every vault. Still a third-party app, still has no
      # business managing credentials.
      conn =
        conn
        |> oauth_authed(user, %{"scope" => "mcp"})
        |> post("/api/api-keys", %{name: "escalated"})

      assert %{"error" => "oauth_grant_not_allowed"} = json_response(conn, 403)
    end

    test "a grant cannot revoke the user's other connections", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      conn =
        conn
        |> oauth_authed(user, %{"scope" => "mcp", "vault_ids" => [vault.id]})
        |> delete("/api/connections/device/#{Ecto.UUID.generate()}")

      assert %{"error" => "oauth_grant_not_allowed"} = json_response(conn, 403)
    end
  end

  describe "first-party sessions still get through" do
    # The over-block guard. Self-host runs entirely on these tokens, which are
    # internal JWTs just like an OAuth one — discriminating on "internal JWT"
    # instead of the scope claim would lock every self-host user out of their
    # own settings page.
    test "a local session JWT can list connections", %{conn: conn, user: user} do
      conn =
        conn
        |> session_authed(user)
        |> get("/api/connections")

      assert is_list(json_response(conn, 200))
    end

    test "a local session JWT can mint an api key", %{conn: conn, user: user} do
      conn =
        conn
        |> session_authed(user)
        |> post("/api/api-keys", %{name: "legitimate"})

      assert %{"key" => _} = json_response(conn, 200)
    end

    test "a device-flow token is a session, not a grant", %{conn: conn, user: user} do
      # The Obsidian plugin's own token. DeviceFlow mints it via
      # `Accounts.generate_jwt(user)` with NO extras, so it carries no `scope`
      # claim and must not be caught by the OAuth branch.
      conn =
        conn
        |> oauth_authed(user, %{})
        |> get("/api/connections")

      assert is_list(json_response(conn, 200))
    end
  end

  describe "API keys keep their own rejection" do
    test "an api key still gets api_key_not_allowed, not the OAuth code", %{
      conn: conn,
      user: user
    } do
      {:ok, raw_key, _} = Engram.Accounts.create_api_key(user, "a-key")
      # Free tier caps api_rps_cap at 0, so an ungranted key 429s in the outer
      # pipeline before RequireSession ever runs — which would make this assert
      # nothing about the plug.
      grant_api_write!(user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> get("/api/connections")

      assert %{"error" => "api_key_not_allowed"} = json_response(conn, 403)
    end
  end
end
