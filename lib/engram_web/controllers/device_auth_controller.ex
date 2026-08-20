defmodule EngramWeb.DeviceAuthController do
  use EngramWeb, :controller

  alias Engram.Auth.DeviceFlow
  alias Engram.Vaults

  # Fail the link at the moment the user clicks "connect", not later with a
  # silent socket refusal. This route sits on the user-scoped pipeline (it must
  # stay reachable for vault creation), so it does not inherit
  # `RequireOnboarding` from the vault-scoped pipeline — declare it here. The
  # socket-side gate in `SyncChannel`/`CrdtChannel` is the authority; this is
  # the readable error.
  # `skip_vault: true`: this endpoint CREATES the first vault (`vault_id: "new"`),
  # so gating it on "you already have one" makes it permanently unreachable for
  # the exact user who needs it. `Vaults.delete_vault/2` evicts the gate cache
  # on last-vault deletion precisely because zero-vault users are a real state.
  # Every other requirement (terms, subscription, profile) still applies, and
  # the sync channels enforce the vault rule too — nothing reaches data through
  # this relaxation.
  plug EngramWeb.Plugs.RequireOnboarding, [skip_vault: true] when action in [:authorize]

  # Gate new plugin connections at the per-tier obsidian cap. Only on
  # :authorize — start/token/refresh do not mint new connection families.
  plug EngramWeb.Plugs.EnforceDeviceCap when action in [:authorize]

  @verification_path "/link"

  def start(conn, params) do
    client_id = Map.get(params, "client_id", "unknown")
    vault_name = params |> Map.get("vault_name") |> normalize_vault_name()

    case DeviceFlow.start_device_flow(client_id, vault_name) do
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

      {:error, {:vault_limit_reached, limit, current}} ->
        # Free-tier launch §4.5 — standardized 402 shape via LimitResponse.
        EngramWeb.LimitResponse.halt(
          conn,
          "vaults_cap_exceeded",
          :vaults_cap,
          limit,
          current
        )

      {:error, _changeset} ->
        conn |> put_status(422) |> json(%{error: "failed to create vault"})
    end
  end

  def authorize(conn, %{"user_code" => user_code, "vault_id" => vault_id}) do
    user = conn.assigns.current_user

    case Ecto.UUID.cast(vault_id) do
      {:ok, uuid} ->
        do_authorize(conn, user_code, user, uuid)

      :error ->
        conn |> put_status(400) |> json(%{error: "invalid_vault_id"})
    end
  end

  defp do_authorize(conn, user_code, user, vault_id) do
    case DeviceFlow.authorize_device(user_code, user, vault_id) do
      {:ok, auth} ->
        # Wake the waiting plugin now instead of letting it find out on a poll
        # tick. This is a notification only — the plugin still exchanges the
        # code through the single-use REST endpoint. See EngramWeb.DeviceChannel.
        :ok = DeviceFlow.notify_authorized(auth.device_code)
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
        # RFC 8628 §3.5: `authorization_pending` is a 400 carrying the error in
        # the body. The old 428 ("Precondition Required") was never part of the
        # device flow. Clients keyed on 428 are unaffected in practice: both the
        # plugin poll loop and the e2e helpers fall through to "keep polling"
        # on an unrecognised status, and both now accept 400 explicitly.
        #
        # :expected_client_status marks this as a NORMAL protocol step so
        # RequestLogger logs it at :info. This is the happy path — the code is
        # alive and the human just has not clicked approve yet — and at a 5s
        # poll over a 300s TTL one successful login would otherwise emit ~60
        # WARN lines (prod 2026-08-13: ~82% of the warn stream).
        conn
        |> assign(:expected_client_status, true)
        |> put_status(400)
        |> json(%{error: "authorization_pending"})

      {:error, :expired_or_invalid} ->
        conn |> put_status(410) |> json(%{error: "expired_or_invalid"})
    end
  end

  defp normalize_vault_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, 100)
    end
  end

  defp normalize_vault_name(_), do: nil

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
