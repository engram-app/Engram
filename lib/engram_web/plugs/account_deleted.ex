defmodule EngramWeb.Plugs.AccountDeleted do
  @moduledoc """
  Returns 410 Gone for authenticated requests whose user has been soft-
  deleted by the §C inactivity sweep. Sits after auth (current_user is
  set) and before any vault/billing logic.

  The Clerk identity is NOT touched — re-signup with the same email is
  allowed and produces a fresh vault.
  """

  alias EngramWeb.Plugs.Halt

  def init(opts), do: opts

  # Halt.json emits the identical wire response to the Phoenix.Controller.json
  # this replaced (same content type incl. charset, same Jason-encoded body).
  def call(%Plug.Conn{assigns: %{current_user: %{deleted_at: %DateTime{}}}} = conn, _opts) do
    Halt.json(conn, 410, %{
      error: "account_deleted",
      message: "Your vault was auto-deleted after 90 days of inactivity. You can re-signup."
    })
  end

  def call(conn, _opts), do: conn
end
