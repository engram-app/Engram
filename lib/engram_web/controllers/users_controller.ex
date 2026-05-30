defmodule EngramWeb.UsersController do
  use EngramWeb, :controller

  def me(conn, _params) do
    user = conn.assigns.current_user
    # `role` is included so the SPA admin gate can decide whether to render the
    # self-host Administration section (paired with `config.authProvider`).
    json(conn, %{user: %{id: user.id, email: user.email, role: user.role}})
  end
end
