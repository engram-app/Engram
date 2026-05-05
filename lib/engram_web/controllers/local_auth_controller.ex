defmodule EngramWeb.LocalAuthController do
  use EngramWeb, :controller

  alias Engram.Accounts
  alias Engram.Auth.Providers.Local

  @refresh_cookie_base [
    http_only: true,
    same_site: "Lax",
    path: "/api/auth",
    max_age: 30 * 24 * 3600
  ]

  defp refresh_cookie_opts(conn) do
    secure = conn.scheme == :https
    Keyword.put(@refresh_cookie_base, :secure, secure)
  end

  def register(conn, %{"email" => email, "password" => password})
      when is_binary(email) and is_binary(password) do
    # Normalize timing: always run bcrypt even if we'll fail on duplicate email
    case Local.register_user(email, password, %{}) do
      {:ok, %{external_id: ext_id, email: user_email}} ->
        with {:ok, user} <- Accounts.find_by_external_id(ext_id),
             {:ok, access_token} <- Local.issue_access_token(ext_id, user_email),
             {:ok, raw_refresh, _record} <- Accounts.create_refresh_token(user) do
          conn
          |> put_resp_cookie("refresh_token", raw_refresh, refresh_cookie_opts(conn))
          |> put_status(:created)
          |> json(%{access_token: access_token, user: %{email: user.email, role: user.role}})
        else
          {:error, _} ->
            conn |> put_status(500) |> json(%{error: "session_creation_failed"})
        end

      {:error, :password_too_short} ->
        conn |> put_status(422) |> json(%{error: "password_too_short"})

      {:error, :password_too_long} ->
        conn |> put_status(422) |> json(%{error: "password_too_long"})

      {:error, %Ecto.Changeset{}} ->
        # Unique constraint or other validation failure — normalize timing
        Bcrypt.no_user_verify()
        conn |> put_status(422) |> json(%{error: "registration_failed"})

      {:error, _} ->
        conn |> put_status(422) |> json(%{error: "registration_failed"})
    end
  end

  def register(conn, _params) do
    conn |> put_status(422) |> json(%{error: "email and password required"})
  end

  def login(conn, %{"email" => email, "password" => password}) do
    case Local.authenticate_credentials(email, password) do
      {:ok, %{external_id: ext_id, email: user_email}} ->
        with {:ok, user} <- Accounts.find_by_external_id(ext_id),
             {:ok, access_token} <- Local.issue_access_token(ext_id, user_email),
             {:ok, raw_refresh, _record} <- Accounts.create_refresh_token(user) do
          conn
          |> put_resp_cookie("refresh_token", raw_refresh, refresh_cookie_opts(conn))
          |> json(%{access_token: access_token, user: %{email: user.email, role: user.role}})
        else
          {:error, _} ->
            conn |> put_status(500) |> json(%{error: "session_creation_failed"})
        end

      {:error, _} ->
        conn |> put_status(401) |> json(%{error: "invalid_credentials"})
    end
  end

  def refresh(conn, _params) do
    conn = fetch_cookies(conn)

    case conn.req_cookies["refresh_token"] do
      nil ->
        conn |> put_status(401) |> json(%{error: "no_refresh_token"})

      raw_token ->
        case Accounts.consume_refresh_token(raw_token) do
          {:ok, user, new_raw_token, _record} ->
            case Local.issue_access_token(user.external_id, user.email) do
              {:ok, access_token} ->
                conn
                |> put_resp_cookie("refresh_token", new_raw_token, refresh_cookie_opts(conn))
                |> json(%{access_token: access_token})

              {:error, _} ->
                conn |> put_status(500) |> json(%{error: "token_signing_failed"})
            end

          {:error, _reason} ->
            conn
            |> delete_resp_cookie("refresh_token", path: "/api/auth")
            |> put_status(401)
            |> json(%{error: "invalid_refresh_token"})
        end
    end
  end

  def logout(conn, _params) do
    conn = fetch_cookies(conn)

    case conn.req_cookies["refresh_token"] do
      nil ->
        :ok

      raw_token ->
        token_hash = Accounts.hash_refresh_token(raw_token)
        Accounts.revoke_token_family(token_hash)
    end

    conn
    |> delete_resp_cookie("refresh_token", path: "/api/auth")
    |> send_resp(204, "")
  end
end
