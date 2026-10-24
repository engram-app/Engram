defmodule EngramWeb.Plugs.AccountDeleted do
  @moduledoc """
  Returns 410 Gone for authenticated requests whose user carries `deleted_at`.
  Sits after auth (current_user is set) and before any vault/billing logic.

  `deleted_at` is set by every delete path: the user's own delete, a Clerk
  `user.deleted`, and the inactivity sweep. The row does not record which, so
  `deny/1`'s copy must be true for all three. `EngramWeb.Plugs.AccountLifecycle`
  sends the same response through `deny/1`.

  The Clerk identity is NOT touched — re-signup with the same email is
  allowed and produces a fresh vault.
  """

  alias EngramWeb.Plugs.Halt

  def init(opts), do: opts

  def call(%Plug.Conn{assigns: %{current_user: %{deleted_at: %DateTime{}}}} = conn, _opts),
    do: deny(conn)

  def call(conn, _opts), do: conn

  @doc "Halts with the 410 every deleted-account gate returns."
  # Halt.json emits the identical wire response to the Phoenix.Controller.json
  # this replaced (same content type incl. charset, same Jason-encoded body).
  @spec deny(Plug.Conn.t()) :: Plug.Conn.t()
  def deny(conn) do
    Halt.json(conn, 410, %{
      error: "account_deleted",
      message: "This account has been deleted. You can sign up again with the same email."
    })
  end
end
