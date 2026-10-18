defmodule EngramWeb.Plugs.OAuthScopeEnforce do
  @moduledoc """
  Surfaces OAuth scope claims (`vault_ids`, `scope`) from an Engram-issued
  internal HS256 JWT (the kind minted by `/oauth/token`) so downstream
  callers can enforce the grant's vault scope on the bearer token.

  Mounted on `/api/mcp` and on the vault-scoped REST pipeline, AFTER
  `EngramWeb.Plugs.Auth`. Auth has already validated the token in full, so
  this plug only reads its claims back (`Engram.Accounts.grant_claims/1`:
  signature checked, expiry not re-checked). Re-validating used to fail for a
  token in its final second, after Auth had passed it, and its grant then
  read as absent: unrestricted. If Auth marked the request as an internal JWT
  (`:current_auth_method`) and its claims still cannot be read, the request
  is refused with 401: an unreadable grant never means "no restriction".

  Sets `conn.assigns.oauth_scope_vault_ids` (a list of vault id strings, or
  nil for an unrestricted grant), `conn.assigns.oauth_scope` (string or
  nil), and `conn.assigns.device_token` (true for a plugin device-flow
  token, read by `RequireSession`). Absence of OAuth claims is the normal case for
  API-key / Clerk JWT auth, and means unrestricted.

  Also sets `conn.assigns.oauth_access`, the grant's per-vault levels
  (`Engram.Permissions.from_claims/1`), which `Permissions.vault_scope/1`
  reads; `VaultPlug` refuses writes to a read-level vault from it.

  Halts with 403 `read_only_grant` when the request's credential, whatever
  its kind, can write NO vault (`Permissions.vault_scope/1`: an `mcp:read`
  grant, an all-read grant or a read-only API key, #174 / #332) and the
  request can write (`EngramWeb.ReadOnlyRoutes`). That covers the
  account-level routes no vault check guards (`PATCH /api/me`, onboarding
  actions, vault registration). The POSTs that write no vault data
  (`/api/feedback`, `/api/telemetry/spans`) stay allowed for such a
  credential, as `send_feedback` is on MCP (`ReadOnlyRoutes` lists them). The MCP access token also
  authenticates the REST API (`get_attachment_upload_target` tells the model
  to POST there with it), so "read only" would be a lie if only the MCP tool
  list enforced it.

  The claim shapes are normalized by `Engram.Permissions.scope_ids_from_claims/1`,
  shared with `UserSocket` so the HTTP and WebSocket assigns cannot drift.
  """
  import Plug.Conn

  alias Engram.Permissions
  alias EngramWeb.Plugs.Halt

  @mcp_audience Engram.Token.mcp_audience()

  def init(opts), do: opts

  def call(conn, _opts) do
    case assign_grant(conn) do
      %Plug.Conn{halted: true} = halted -> halted
      conn -> refuse_write_without_writable_vault(conn)
    end
  end

  defp assign_grant(conn) do
    case read_grant(conn) do
      {:ok, claims} ->
        conn
        |> assign(:oauth_scope_vault_ids, Permissions.scope_ids_from_claims(claims))
        |> assign(:oauth_access, Permissions.from_claims(claims))
        |> assign(:oauth_scope, claims["scope"])
        |> assign(:device_token, claims["cred"] == "device")
        # The grant (refresh-token family) behind an OAuth access token, read
        # by `VaultsController.restore` to refuse vaults deleted before it.
        |> assign(:oauth_grant_id, claims["gid"])
        |> require_mcp_scope(claims)

      # Our token, but its grant was revoked: refused on every auth path,
      # including self-host where it authenticated as a provider JWT.
      :revoked ->
        Halt.json(conn, 401, %{error: "unauthorized"})

      _ ->
        unreadable_grant(conn, conn.assigns[:current_auth_method])
    end
  end

  # `Plugs.Auth` already read the token's grant (and refused a revoked one)
  # and kept the result; read it here only when this plug runs without it.
  defp read_grant(%{assigns: %{grant_claims: claims}}), do: claims

  defp read_grant(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> Engram.Accounts.grant_claims(token)
      _ -> :error
    end
  end

  defp unreadable_grant(conn, :internal_jwt), do: Halt.json(conn, 401, %{error: "unauthorized"})
  defp unreadable_grant(conn, _method), do: conn

  defp refuse_write_without_writable_vault(conn) do
    if EngramWeb.ReadOnlyRoutes.writes?(conn) and not writable_anywhere?(conn) do
      Halt.json(conn, 403, %{error: "read_only_grant"})
    else
      conn
    end
  end

  # An unrestricted credential writes everywhere: answered without reading
  # the vault list.
  defp writable_anywhere?(conn) do
    case Permissions.vault_scope(conn) do
      :all -> true
      scope -> Permissions.writable_anywhere?(scope, live_vault_ids(conn))
    end
  end

  # Only listed vaults that are live count toward "writable somewhere": a
  # write level on a deleted vault writes nothing. The one exception is the
  # vault a restore names, which the request is about to bring back;
  # `VaultsController.restore` then requires an explicitly listed write on it.
  # Before Auth resolves a user there is no credential to judge.
  defp live_vault_ids(%{assigns: %{current_user: %{} = user}} = conn),
    do: restoring(conn) ++ Enum.map(Engram.Vaults.list_vaults(user), & &1.id)

  defp live_vault_ids(_conn), do: []

  defp restoring(%{method: "POST", path_info: ["api", "vaults", id, "restore"]}), do: [id]
  defp restoring(_conn), do: []

  # An MCP-audience token must also carry an MCP scope, `mcp` or `mcp:read`
  # (#174; a read-only grant's writes are refused later, per vault). Every
  # grant does today, so this is a guard, not a behaviour change: RFC 6750
  # §3.1's 403 if a token ever arrives without one.
  defp require_mcp_scope(conn, %{"aud" => @mcp_audience} = claims) do
    if claims["scope"]
       |> Kernel.||("")
       |> String.split(" ", trim: true)
       |> Enum.any?(&(&1 in Engram.OAuth.scopes_supported())) do
      conn
    else
      conn
      |> put_resp_header(
        "www-authenticate",
        # MCP 2025-11-25 "Runtime Insufficient Scope Errors": the same
        # `resource_metadata` the 401 carries.
        ~s(Bearer resource_metadata="#{EngramWeb.OAuthMetadata.resource_metadata_url(conn)}", ) <>
          ~s(error="insufficient_scope", scope="mcp")
      )
      |> Halt.json(403, %{error: "insufficient_scope"})
    end
  end

  defp require_mcp_scope(conn, _claims), do: conn
end
