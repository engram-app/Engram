defmodule EngramWeb.Plugs.RequireApiRpsBudget do
  @moduledoc """
  Pricing v2 §G — per-plan RPS cap on authenticated API requests.

  Looks up the user's `api_rps_cap` from `Engram.Billing` and rate-limits
  via Hammer with a 1-second window. JWT-authed requests (web app) are
  exempt; the gate only fires for API-key-authed traffic, mirroring the
  policy shape in `RequireApiWriteEnabled`.

  Free defaults to `0` (no API access). Starter `10`, Pro `30`. When the
  cap is exhausted within the window, responds 429 with
  `{"error": "api_rps_exceeded", "limit": N, "period_ms": 1000}`.

  Self-host with `ENGRAM_LIMITS_ENFORCED=false` short-circuits to
  `:unlimited` via `Billing.effective_limit/2` — no Hammer call.
  """

  import Plug.Conn

  alias Engram.Billing

  @period_ms 1_000

  def init(opts), do: opts

  # JWT-authed (no API key) is exempt — web app is not subject to this gate.
  def call(%Plug.Conn{assigns: assigns} = conn, _opts)
      when not is_map_key(assigns, :current_api_key),
      do: conn

  def call(%Plug.Conn{assigns: %{current_user: user}} = conn, _opts) do
    case Billing.effective_limit(user, :api_rps_cap) do
      :unlimited -> conn
      nil -> conn
      0 -> deny(conn, 0)
      limit when is_integer(limit) and limit > 0 -> check_hammer(conn, user, limit)
      _ -> conn
    end
  end

  defp check_hammer(conn, user, limit) do
    case Hammer.check_rate("api_rps:#{user.id}", @period_ms, limit) do
      {:allow, _count} -> conn
      {:deny, _limit} -> deny(conn, limit)
    end
  end

  defp deny(conn, limit) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      429,
      Jason.encode!(%{
        error: "api_rps_exceeded",
        limit: limit,
        period_ms: @period_ms
      })
    )
    |> halt()
  end
end
