defmodule EngramWeb.Plugs.VaultPlug do
  @moduledoc """
  Resolves vault context from the X-Vault-ID header.

  - If X-Vault-ID is present: fetches that vault and verifies the current user owns it.
  - If absent: falls back to the user's default vault.
  - If an API key is present in assigns, checks api_key_vaults for vault restrictions.

  Sets `conn.assigns.current_vault` on success. Halts with 403/404 on failure.

  Assumes Auth plug has already run and set `conn.assigns.current_user`.
  """

  import Plug.Conn

  alias Engram.Vaults

  def init(opts), do: opts

  def call(conn, _opts) do
    user = conn.assigns.current_user

    case resolve_vault(conn, user) do
      {:ok, vault} ->
        api_key = conn.assigns[:current_api_key]

        case Vaults.check_api_key_access(api_key, vault) do
          :ok -> assign(conn, :current_vault, vault)
          :forbidden -> halt_with(conn, 403, "API key does not have access to this vault")
        end

      # A non-UUID X-Vault-ID (e.g. a client sending a stale/placeholder id like
      # `demo-vault-2`) is distinct from a well-formed id that does not resolve.
      # Both are 404 to the client, but the reason rides the existing request-stop
      # log (RequestLogger reads :reject_reason) so the difference is a one-line
      # Loki query without emitting a second log line per rejected request.
      {:error, :malformed_vault_id} ->
        reject(conn, "vault_id_malformed", "Vault not found")

      {:error, :not_found} ->
        reject(conn, "vault_not_found", "Vault not found")

      {:error, :no_default_vault} ->
        reject(conn, "no_default_vault", "No vault configured. Sync from Obsidian to create one.")
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
    |> halt_with(404, message)
  end

  defp halt_with(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: message}))
    |> halt()
  end
end
