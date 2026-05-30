defmodule EngramWeb.PasswordController do
  use EngramWeb, :controller
  alias Engram.Accounts
  alias Engram.Accounts.PasswordReset

  @doc """
  Public reset: the one-time token is the credential. On success, the
  PasswordReset.redeem/2 path also revokes the user's existing refresh
  tokens (spec §8/§10).
  """
  def reset(conn, %{"token" => token, "password" => password}) do
    case PasswordReset.redeem(token, password) do
      {:ok, _user} -> json(conn, %{ok: true})
      {:error, :invalid} -> conn |> put_status(422) |> json(%{error: "invalid_token"})
      {:error, _} -> conn |> put_status(422) |> json(%{error: "reset_failed"})
    end
  end

  @doc """
  Authenticated change: requires the old password. On success, invalidates
  other sessions (spec §8/§10) — this session's cookie still holds the
  refresh token the caller already has, which is also revoked, so the SPA
  should re-login after a successful change.
  """
  def change(conn, %{"old_password" => old, "new_password" => new}) do
    user = conn.assigns.current_user

    case Accounts.verify_password(user.email, old) do
      {:ok, _} ->
        case Accounts.update_password(user, new) do
          {:ok, updated} ->
            Accounts.revoke_all_user_tokens(updated)
            json(conn, %{ok: true})

          {:error, _} ->
            conn |> put_status(422) |> json(%{error: "change_failed"})
        end

      {:error, _} ->
        conn |> put_status(422) |> json(%{error: "invalid_password"})
    end
  end
end
