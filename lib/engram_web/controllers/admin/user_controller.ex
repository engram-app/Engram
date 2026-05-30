defmodule EngramWeb.Admin.UserController do
  use EngramWeb, :controller
  alias Engram.Accounts
  alias Engram.Accounts.PasswordReset
  alias Engram.Accounts.User
  alias Engram.Repo

  def index(conn, _params) do
    json(conn, %{users: Enum.map(Accounts.list_users(), &render_user/1)})
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
      {:ok, u} -> json(conn, %{user: render_user(u)})
      {:error, :last_admin} -> conn |> put_status(409) |> json(%{error: "last_admin"})
      {:error, :no_op} -> conn |> put_status(422) |> json(%{error: "no_op"})
      {:error, _} -> conn |> put_status(422) |> json(%{error: "update_failed"})
    end
  end

  def delete(conn, %{"id" => id}) do
    user = Repo.get!(User, id, skip_tenant_check: true)

    case Accounts.soft_delete_user(user) do
      {:ok, deleted} ->
        # Spec §7: purge vault data, not just the user row.
        Accounts.purge_user_vaults(deleted)
        # 200 + JSON (not 204): the frontend `api.del` parses the body.
        json(conn, %{ok: true})

      {:error, :last_admin} ->
        conn |> put_status(409) |> json(%{error: "last_admin"})
    end
  end

  def password_reset(conn, %{"id" => id}) do
    user = Repo.get!(User, id, skip_tenant_check: true)
    {:ok, {raw, _tok}} = PasswordReset.issue(user, conn.assigns.current_user)

    conn
    |> put_status(:created)
    |> json(%{token: raw, url: "#{conn.scheme}://#{conn.host}/reset-password?token=#{raw}"})
  end

  defp render_user(u) do
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
