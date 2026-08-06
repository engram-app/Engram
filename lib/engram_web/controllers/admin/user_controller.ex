defmodule EngramWeb.Admin.UserController do
  use EngramWeb, :controller
  alias Engram.Accounts
  alias Engram.Accounts.PasswordReset
  alias Engram.Accounts.User
  alias Engram.Repo

  action_fallback EngramWeb.FallbackController

  def index(conn, _params) do
    json(conn, %{users: Enum.map(Accounts.list_users(), &admin_view/1)})
  end

  def update(conn, %{"id" => id} = params) do
    user = Repo.get!(User, id, skip_tenant_check: true)

    result =
      cond do
        Map.has_key?(params, "role") -> Accounts.set_role(user, params["role"])
        params["suspended"] == true -> Accounts.suspend(user)
        params["suspended"] == false -> Accounts.unsuspend(user)
        true -> {:error, :no_op}
      end

    case result do
      {:ok, u} -> json(conn, %{user: admin_view(u)})
      {:error, :last_admin} = error -> error
      {:error, :no_op} -> conn |> put_status(422) |> json(%{error: "no_op"})
      {:error, :invalid_role} -> conn |> put_status(422) |> json(%{error: "invalid_role"})
      {:error, _} -> conn |> put_status(422) |> json(%{error: "update_failed"})
    end
  end

  def delete(conn, %{"id" => id}) do
    user = Repo.get!(User, id, skip_tenant_check: true)

    # {:error, :last_admin} falls through to the action_fallback (409).
    with {:ok, deleted} <- Accounts.soft_delete_user(user) do
      # Spec §7: purge vault data, not just the user row.
      Accounts.purge_user_vaults(deleted)
      # 200 + JSON (not 204): the frontend `api.del` parses the body.
      json(conn, %{ok: true})
    end
  end

  def password_reset(conn, %{"id" => id}) do
    user = Repo.get!(User, id, skip_tenant_check: true)

    case PasswordReset.issue(user, conn.assigns.current_user) do
      {:ok, {raw, _tok}} ->
        conn
        |> put_status(:created)
        # Canonical URL, never the connection. `conn.scheme` is :http on every
        # saas deployment (TLS terminates at the edge), which would emit a
        # plaintext link carrying this live token in its query string; and
        # `conn.host` is whichever backend host the admin happened to reach —
        # `api.engram.page` serves no SPA, so that link 404s too. Same source
        # the device-flow `verification_url` and account emails already use.
        |> json(%{token: raw, url: EngramWeb.Endpoint.url() <> "/reset-password?token=#{raw}"})

      {:error, _cs} ->
        conn |> put_status(422) |> json(%{error: "reset_issue_failed"})
    end
  end

  defp admin_view(u) do
    %{
      id: u.id,
      email: u.email,
      role: u.role,
      display_name: u.display_name,
      suspended: not is_nil(u.suspended_at),
      created_at: u.created_at,
      last_active: Engram.UsageMeters.last_active_at(u.id)
    }
  end
end
