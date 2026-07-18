defmodule EngramWeb.ReportController do
  @moduledoc "POST /api/reports: authenticated, rate-limited user issue reports."
  use EngramWeb, :controller
  alias Engram.Support

  # 5 reports per hour per user.
  @rate_scale_ms 3_600_000
  @rate_limit 5

  def create(conn, params) do
    user = conn.assigns.current_user

    if rate_limited?(user.id) do
      conn |> put_status(429) |> json(%{error: "rate_limited"})
    else
      meta = %{
        vault_id: conn |> get_req_header("x-vault-id") |> List.first(),
        device_fingerprint: fingerprint(conn)
      }

      case Support.create_report(user, params, meta) do
        {:ok, report} ->
          conn |> put_status(201) |> json(%{report: %{id: report.id, status: report.status}})

        {:error, changeset} ->
          conn |> put_status(422) |> json(%{errors: format_errors(changeset)})
      end
    end
  end

  defp rate_limited?(user_id) do
    case EngramWeb.RateLimiter.hit("report:#{user_id}", @rate_scale_ms, @rate_limit, :other) do
      {:allow, _} -> false
      {:deny, _} -> true
    end
  end

  defp fingerprint(conn) do
    ua = conn |> get_req_header("user-agent") |> List.first() || ""
    EngramWeb.Plugs.DeviceFingerprint.hash_ua(ua)
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
  end
end
