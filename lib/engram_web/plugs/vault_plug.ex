defmodule EngramWeb.Plugs.VaultPlug do
  @moduledoc """
  Resolves vault context from the X-Vault-ID header.

  - If X-Vault-ID is present: fetches that vault and verifies the current user owns it.
  - If absent: falls back to the user's default vault.
  - Restrictions (API key, OAuth grant) are enforced via `Engram.Permissions`,
    including per-vault levels: a write to a read-level vault is 403
    `read_only_vault`.
  - A vault the credential cannot reach at all answers exactly like a vault
    that does not exist (404 "Vault not found"), so a credential cannot probe
    which UUIDs are real.

  Sets `conn.assigns.current_vault` on success. Halts with 403/404 on failure.

  Assumes Auth plug has already run and set `conn.assigns.current_user`.
  """

  import Plug.Conn

  alias Engram.Vaults
  alias EngramWeb.Plugs.Halt

  def init(opts), do: opts

  def call(conn, _opts) do
    user = conn.assigns.current_user

    case resolve_vault(conn, user) do
      {:ok, vault} ->
        need = if EngramWeb.ReadOnlyRoutes.writes?(conn), do: :write, else: :read

        case Engram.Permissions.decide(Engram.Permissions.vault_scope(conn), vault, need) do
          :ok ->
            assign(conn, :current_vault, vault)

          # A read-level vault (#174, #332) refuses anything that can change it.
          :read_only ->
            Halt.json(conn, 403, %{error: "read_only_vault"})

          # Same response as a UUID that resolves to nothing: a 403 here told
          # a restricted credential the vault exists. The reason differs only
          # in the request log.
          :forbidden ->
            reject(conn, "vault_out_of_scope", "Vault not found")

          # A grant gone since `Plugs.Auth` read it: refused like Auth would.
          :revoked ->
            Halt.json(conn, 401, %{error: "unauthorized"})
        end

      # A non-UUID X-Vault-ID (e.g. a client sending a stale/placeholder id) is
      # distinct from a well-formed id that does not resolve.
      # Both are 404 to the client, but the reason rides the existing request-stop
      # log (RequestLogger reads :reject_reason) so the difference is a one-line
      # Loki query without emitting a second log line per rejected request.
      {:error, :malformed_vault_id} ->
        reject(conn, "vault_id_malformed", "Vault not found")

      {:error, :not_found} ->
        reject(conn, "vault_not_found", "Vault not found")

      {:error, :no_default_vault} ->
        reject(conn, "no_default_vault", EngramWeb.FrontendUrl.no_vault_message())
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp resolve_vault(conn, user) do
    case get_req_header(conn, "x-vault-id") do
      [vault_id_str | _] ->
        case Ecto.UUID.cast(vault_id_str) do
          {:ok, vault_id} -> Vaults.get_vault(user, vault_id)
          :error -> {:error, :malformed_vault_id}
        end

      [] ->
        Vaults.get_default_vault(user)
    end
  end

  # Stash the reason on the conn for RequestLogger to fold into the single
  # request-stop log line (no second log per rejection). Category/level come from
  # RequestLogger's :http request log; the raw vault id is not logged (correlate
  # via trace_id / the Sentry request-env URL).
  defp reject(conn, reason, message) do
    conn
    |> assign(:reject_reason, reason)
    |> Halt.json(404, %{error: message})
  end
end
