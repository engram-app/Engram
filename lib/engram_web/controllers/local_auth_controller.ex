defmodule EngramWeb.LocalAuthController do
  use EngramWeb, :controller

  alias Engram.Accounts
  alias Engram.Auth.Providers.Local
  alias Engram.Instance
  alias Engram.Invites

  @refresh_cookie_base [
    http_only: true,
    same_site: "Lax",
    path: "/api/auth",
    max_age: 30 * 24 * 3600
  ]

  # Canonical URL, never the connection. `conn.scheme` is :http on every
  # deployment that terminates TLS at an edge (ALB in saas, the operator's
  # reverse proxy in self-host, and self-host is the ONLY shape that reaches
  # this controller — see RequireLocalAuth on the router), so deriving the
  # flag from the conn shipped this 30-day refresh token with no `Secure`
  # attribute and let a downgrade replay it over cleartext.
  #
  # Deliberately NOT `Plug.RewriteOn`/`x-forwarded-proto`: that trusts a
  # client-settable header, and it silently no-ops on the header shapes real
  # proxy chains emit. `Plug.RewriteOn` matches the literal lowercase "https"
  # only, so an uppercase `HTTPS` or the appended `https,http` a CDN in front
  # of nginx produces both fall through to a bare `conn` with no log and no
  # error, i.e. the bug comes back invisibly.
  #
  # Same source `Endpoint.url()` already backs for the device-flow
  # verification URL, account emails, and the admin reset link.
  #
  # Ceiling, stated in full because an earlier revision of this comment listed
  # only the first case and the second one is a functional break, not a missed
  # hardening:
  #
  #   1. PHX_HOST/PHX_SCHEME unset -> the `http://localhost` default -> no
  #      Secure flag. Same single point of truth every link this app emits
  #      already depends on, so not a new failure mode. `Engram.Application`
  #      warns about this at boot.
  #   2. Multi-host (`PHX_HOST=a,b`) where the request arrives on a
  #      NON-canonical host -> no Secure flag, because we cannot know that
  #      host's scheme. Handled by the host check below rather than ignored:
  #      the alternative (trusting the canonical scheme for every host) breaks
  #      login outright on the plaintext one.
  defp refresh_cookie_opts(conn) do
    %URI{scheme: scheme, host: canonical_host} = URI.parse(EngramWeb.Endpoint.url())

    # BOTH conditions, and the host half is not redundant.
    #
    # `PHX_HOST` is documented as comma-separated with the FIRST entry
    # canonical (`.env.example` gives `engram.example.com,10.0.20.5:4000` as an
    # example), and `HostOrigins.parse/1` admits http AND https for EVERY entry.
    # So a self-host box is routinely reachable on a TLS public name and a
    # plaintext LAN address at the same time, and only the canonical one is
    # described by `Endpoint.url()`.
    #
    # Deriving `secure` from the canonical scheme alone therefore marks the
    # cookie Secure for the LAN user too. Their login looks fine (201 + a valid
    # access token), the browser silently discards a Secure cookie sent over
    # cleartext, and `/api/auth/refresh` 401s forever once that token expires.
    # Comparing the dialed host keeps the flag tied to the connection it was
    # actually derived for.
    #
    # Safe against a forged Host: a browser sets Host from the URL the user
    # navigated to, so an attacker cannot choose the victim's value. And the
    # only reachable mistake is the SAFE direction — an unexpected host yields
    # `secure: false`, which is exactly the pre-existing behaviour, never a
    # downgrade of a cookie that would otherwise be protected.
    secure = scheme == "https" and conn.host == canonical_host

    Keyword.put(@refresh_cookie_base, :secure, secure)
  end

  def register(conn, %{"email" => email, "password" => password} = params)
      when is_binary(email) and is_binary(password) do
    case check_registration_allowed(Map.get(params, "invite")) do
      :ok ->
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

      {:error, status, code} ->
        Bcrypt.no_user_verify()
        conn |> put_status(status) |> json(%{error: code})
    end
  end

  def register(conn, _params) do
    conn |> put_status(422) |> json(%{error: "email and password required"})
  end

  # Claim-window first: until bootstrap closes, registration is open and the
  # first user becomes admin inside `Accounts.create_user_with_password/2`
  # (advisory-locked, atomic with the bootstrap flag flip). Race note: the
  # invite is redeemed BEFORE user creation; if creation then fails on a
  # duplicate email the invite is already consumed — acceptable for v1.
  defp check_registration_allowed(invite) do
    if Instance.bootstrap_pending?() do
      :ok
    else
      case Instance.registration_mode() do
        "open" -> :ok
        "closed" -> {:error, 403, "registration_closed"}
        "invite_only" -> check_invite(invite)
      end
    end
  end

  defp check_invite(nil), do: {:error, 403, "invite_required"}

  defp check_invite(token) when is_binary(token) do
    case Invites.redeem(token) do
      {:ok, _invite} -> :ok
      {:error, :invalid} -> {:error, 403, "invite_invalid"}
    end
  end

  defp check_invite(_), do: {:error, 403, "invite_invalid"}

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

      # Distinct from invalid_credentials: the password was correct but the
      # account is administratively blocked. Self-host operator surface — we
      # accept the existence-leak in exchange for a useful error message.
      {:error, :suspended} ->
        conn |> put_status(403) |> json(%{error: "account_suspended"})

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

  @doc """
  Public preview for an invite link. Non-enumerating: returns `%{valid: false}`
  for any unknown/expired/revoked/exhausted token rather than 404.
  """
  def invite_preview(conn, %{"token" => token}) do
    json(conn, Invites.preview(token))
  end

  @doc """
  Public self-host bootstrap probe. Returns the state the unauthenticated
  sign-in/sign-up pages need to render the first-run experience:
  `bootstrap_pending` (admin claim window still open) + `registration_mode`.
  404 under Clerk — the feature is local-provider-only.
  """
  def bootstrap(conn, _params) do
    if Engram.Auth.supports_credentials?() do
      json(conn, %{
        bootstrap_pending: Instance.bootstrap_pending?(),
        registration_mode: Instance.registration_mode()
      })
    else
      conn |> put_status(404) |> json(%{error: "not_found"})
    end
  end
end
