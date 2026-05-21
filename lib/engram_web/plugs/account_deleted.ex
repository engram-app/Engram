defmodule EngramWeb.Plugs.AccountDeleted do
  @moduledoc """
  Returns 410 Gone for authenticated requests whose user has been soft-
  deleted by the §C inactivity sweep. Sits after auth (current_user is
  set) and before any vault/billing logic.

  The Clerk identity is NOT touched — re-signup with the same email is
  allowed and produces a fresh vault.
  """

  import Plug.Conn
  alias Phoenix.Controller

  def init(opts), do: opts

  def call(%Plug.Conn{assigns: %{current_user: %{deleted_at: %DateTime{}}}} = conn, _opts) do
    conn
    |> put_status(410)
    |> Controller.json(%{
      error: "account_deleted",
      message: "Your vault was auto-deleted after 90 days of inactivity. You can re-signup."
    })
    |> halt()
  end

  def call(conn, _opts), do: conn
end
