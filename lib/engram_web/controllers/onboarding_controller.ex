defmodule EngramWeb.OnboardingController do
  use EngramWeb, :controller

  alias Engram.Onboarding

  def status(conn, _params) do
    user = conn.assigns.current_user
    state = Onboarding.status(user)

    payload =
      case state do
        %{enabled: false} ->
          %{enabled: false, next_step: "done"}

        %{
          enabled: true,
          terms_ok: terms_ok,
          subscription_ok: sub_ok,
          current_tos_version: version,
          current_privacy_version: privacy_version,
          next_step: next
        } ->
          %{
            enabled: true,
            terms_ok: terms_ok,
            subscription_ok: sub_ok,
            current_tos_version: version,
            current_privacy_version: privacy_version,
            next_step: Atom.to_string(next)
          }
      end

    json(conn, payload)
  end

  def accept_terms(conn, %{
        "tos_version" => tv,
        "tos_hash" => th,
        "privacy_version" => pv,
        "privacy_hash" => ph
      }) do
    # Verify BOTH documents' version + content hash against the canonical config.
    # Any mismatch means the app is showing different text than the backend
    # expects (drift) — refuse with 409 instead of recording bad consent.
    ok =
      tv == Application.get_env(:engram, :current_tos_version) and
        th == Application.get_env(:engram, :current_tos_hash) and
        pv == Application.get_env(:engram, :current_privacy_version) and
        ph == Application.get_env(:engram, :current_privacy_hash)

    if ok do
      meta = %{
        ip_address: format_ip(conn.remote_ip),
        user_agent: get_user_agent(conn)
      }

      case Onboarding.accept_terms(conn.assigns.current_user, tv, th, pv, ph, meta) do
        {:ok, agreement} ->
          conn
          |> put_status(:created)
          |> json(%{version: agreement.version, accepted_at: agreement.accepted_at})

        {:error, _changeset} ->
          conn |> put_status(422) |> json(%{error: "invalid"})
      end
    else
      conn |> put_status(409) |> json(%{error: "stale"})
    end
  end

  def accept_terms(conn, _params) do
    conn |> put_status(422) |> json(%{error: "missing_fields"})
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(tuple) when tuple_size(tuple) == 8, do: tuple |> :inet.ntoa() |> to_string()
  defp format_ip(_), do: nil

  defp get_user_agent(conn) do
    case Plug.Conn.get_req_header(conn, "user-agent") do
      [ua | _] -> ua
      _ -> nil
    end
  end
end
