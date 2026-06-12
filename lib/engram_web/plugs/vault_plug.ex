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

      {:error, :not_found} ->
        halt_with(conn, 404, "Vault not found")

      {:error, :no_default_vault} ->
        halt_with(conn, 404, "No vault configured. Sync from Obsidian to create one.")
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp resolve_vault(conn, user) do
    case get_req_header(conn, "x-vault-id") do
      [vault_id_str | _] ->
        case Ecto.UUID.cast(vault_id_str) do
          {:ok, vault_id} -> Vaults.get_vault(user, vault_id)
          :error -> {:error, :not_found}
        end

      [] ->
        Vaults.get_default_vault(user)
    end
  end

  defp halt_with(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: message}))
    |> halt()
  end
end
