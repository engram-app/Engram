defmodule EngramWeb.Plugs.AccountLifecycle do
  @moduledoc """
  Request-time lifecycle gate for authenticated users. Runs after
  `EngramWeb.Plugs.Auth` (so `current_user` is set) on every authenticated
  pipeline — user-scoped, onboarding, and vault-scoped.

  Without this, a user soft-deleted by the inactivity sweep or suspended by an
  admin still holds a valid JWT until it expires, and could keep using the
  management plane (mint API keys, CRUD vaults, change billing). This closes
  that window.

  ## Deleted (`deleted_at`)

  Terminal. Returns **410 Gone** on every endpoint, no exemptions — the vault
  was auto-deleted after 90 days of inactivity; the path forward is re-signup
  (the Clerk identity is untouched).

  ## Suspended (`suspended_at`)

  Admin action (abuse/fraud). Returns **403 Forbidden** EXCEPT on a small
  allowlist so the SPA can explain the state and the user can still settle up:

    * `GET /api/me` — read own status
    * `GET /api/onboarding/status` — onboarding status read
    * `/api/billing/*` (any method) — view + self-reactivate (pay)

  Deleted takes precedence over suspended.
  """

  import Plug.Conn
  alias Phoenix.Controller

  def init(opts), do: opts

  def call(%Plug.Conn{assigns: %{current_user: %{deleted_at: %DateTime{}}}} = conn, _opts) do
    deny(
      conn,
      410,
      "account_deleted",
      "Your vault was auto-deleted after 90 days of inactivity. You can re-signup."
    )
  end

  def call(%Plug.Conn{assigns: %{current_user: %{suspended_at: %DateTime{}}}} = conn, _opts) do
    if suspension_exempt?(conn) do
      conn
    else
      deny(
        conn,
        403,
        "account_suspended",
        "Your account is suspended. Contact support to resolve it."
      )
    end
  end

  def call(conn, _opts), do: conn

  defp suspension_exempt?(%Plug.Conn{method: "GET", request_path: "/api/me"}), do: true

  defp suspension_exempt?(%Plug.Conn{method: "GET", request_path: "/api/onboarding/status"}),
    do: true

  defp suspension_exempt?(%Plug.Conn{request_path: path}),
    do: String.starts_with?(path, "/api/billing/")

  defp deny(conn, status, error, message) do
    conn
    |> put_status(status)
    |> Controller.json(%{error: error, message: message})
    |> halt()
  end
end
