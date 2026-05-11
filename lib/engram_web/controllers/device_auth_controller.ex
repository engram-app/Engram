defmodule EngramWeb.DeviceAuthController do
  use EngramWeb, :controller

  alias Engram.Auth.DeviceFlow
  alias Engram.Vaults

  @verification_path "/link"

  def start(conn, params) do
    client_id = Map.get(params, "client_id", "unknown")

    case DeviceFlow.start_device_flow(client_id) do
      {:ok, auth} ->
        base_url = EngramWeb.Endpoint.url()

        json(conn, %{
          device_code: auth.device_code,
          user_code: auth.user_code,
          verification_url: base_url <> @verification_path,
          expires_in: 300,
          interval: 5
        })

      {:error, _changeset} ->
        conn |> put_status(422) |> json(%{error: "failed to start device flow"})
    end
  end

  def authorize(conn, %{"user_code" => user_code, "vault_id" => "new", "vault_name" => vault_name}) do
    user = conn.assigns.current_user

    case Vaults.create_vault(user, %{name: vault_name}) do
      {:ok, vault} ->
        do_authorize(conn, user_code, user, vault.id)

      {:error, :vault_limit_reached} ->
        limit = Engram.Billing.effective_limit(user, "max_vaults")
        conn |> put_status(402) |> json(%{error: "vault_limit_reached", limit: limit})

      {:error, _changeset} ->
        conn |> put_status(422) |> json(%{error: "failed to create vault"})
    end
  end

  def authorize(conn, %{"user_code" => user_code, "vault_id" => vault_id}) do
    user = conn.assigns.current_user
    vault_id = if is_binary(vault_id), do: String.to_integer(vault_id), else: vault_id
    do_authorize(conn, user_code, user, vault_id)
  end

  defp do_authorize(conn, user_code, user, vault_id) do
    case DeviceFlow.authorize_device(user_code, user, vault_id) do
      {:ok, auth} ->
        json(conn, %{ok: true, vault_id: auth.vault_id})

      {:error, :not_found_or_expired} ->
        conn |> put_status(404) |> json(%{error: "code not found or expired"})

      {:error, :vault_not_found} ->
        conn |> put_status(403) |> json(%{error: "vault not found or not owned by user"})
    end
  end

  def token(conn, %{"device_code" => device_code}) do
    case DeviceFlow.exchange_device_code(device_code) do
      {:ok, result} ->
        json(conn, %{
          access_token: result.access_token,
          refresh_token: result.refresh_token,
          vault_id: result.vault_id,
          user_email: result.user_email,
          expires_in: result.expires_in
        })

      {:error, :authorization_pending} ->
        conn |> put_status(428) |> json(%{error: "authorization_pending"})

      {:error, :expired_or_invalid} ->
        conn |> put_status(410) |> json(%{error: "expired_or_invalid"})
    end
  end

  def refresh(conn, %{"refresh_token" => refresh_token}) do
    case DeviceFlow.refresh_access_token(refresh_token) do
      {:ok, result} ->
        json(conn, %{
          access_token: result.access_token,
          refresh_token: result.refresh_token,
          expires_in: result.expires_in
        })

      {:error, :invalid_refresh_token} ->
        conn |> put_status(401) |> json(%{error: "invalid or expired refresh token"})
    end
  end
end
