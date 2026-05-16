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
          next_step: next
        } ->
          %{
            enabled: true,
            terms_ok: terms_ok,
            subscription_ok: sub_ok,
            current_tos_version: version,
            next_step: Atom.to_string(next)
          }
      end

    json(conn, payload)
  end

  def accept_terms(conn, %{"version" => version}) do
    user = conn.assigns.current_user
    current_version = Application.get_env(:engram, :current_tos_version)

    if version == current_version do
      meta = %{
        ip_address: format_ip(conn.remote_ip),
        user_agent: get_user_agent(conn)
      }

      case Onboarding.accept_terms(user, version, meta) do
        {:ok, agreement} ->
          conn
          |> put_status(:created)
          |> json(%{version: agreement.version, accepted_at: agreement.accepted_at})

        {:error, _changeset} ->
          conn |> put_status(422) |> json(%{error: "invalid"})
      end
    else
      conn |> put_status(422) |> json(%{error: "version_mismatch"})
    end
  end

  def accept_terms(conn, _params) do
    conn |> put_status(422) |> json(%{error: "missing_version"})
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
