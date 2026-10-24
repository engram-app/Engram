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

  Terminal. Returns **410 Gone** (`EngramWeb.Plugs.AccountDeleted.deny/1`) on
  every endpoint but one: `DELETE /api/me`, so a delete that stamped
  `deleted_at` and then failed its hard delete can be finished by its owner
  (`Engram.Accounts.delete_self/2`, password required). It can only move the
  account further toward gone. The path forward is re-signup.

  ## Suspended (`suspended_at`)

  Admin action (abuse/fraud). Returns **403 Forbidden** EXCEPT on a small
  allowlist so the SPA can explain the state and the user can still settle up:

    * `GET /api/me` — read own status
    * `GET /api/onboarding/status` — onboarding status read
    * `/api/billing/*` (any method) — view + self-reactivate (pay)

  Deleted takes precedence over suspended.
  """

  alias EngramWeb.Plugs.AccountDeleted
  alias EngramWeb.Plugs.Halt

  def init(opts), do: opts

  def call(
        %Plug.Conn{
          assigns: %{current_user: %{deleted_at: %DateTime{}}},
          method: "DELETE",
          request_path: "/api/me"
        } = conn,
        _opts
      ),
      do: conn

  def call(%Plug.Conn{assigns: %{current_user: %{deleted_at: %DateTime{}}}} = conn, _opts),
    do: AccountDeleted.deny(conn)

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

  # Halt.json (put_resp_content_type + send_resp) emits the identical wire
  # response to the Phoenix.Controller.json this replaced: same
  # `application/json; charset=utf-8` content type, same Jason-encoded body.
  defp deny(conn, status, error, message) do
    Halt.json(conn, status, %{error: error, message: message})
  end
end
